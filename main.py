from fastapi import FastAPI, HTTPException
from web3 import Web3
from dotenv import load_dotenv
import json, os, time, traceback, pprint, subprocess

pp = pprint.PrettyPrinter(indent=2)

# ============================================================
# ENV + APP
# ============================================================
load_dotenv()
app = FastAPI()

RPC_URL = os.getenv("RPC_URL")
PRIVATE_KEY = os.getenv("PRIVATE_KEY")
ROULETTE_CONTRACT = Web3.to_checksum_address(os.getenv("ROULETTE_CONTRACT"))
SWITCHBOARD_CONTRACT = Web3.to_checksum_address(os.getenv("SWITCHBOARD_CONTRACT"))
CHAIN_ID = int(os.getenv("CHAIN_ID", "143"))

print("\n================ BOOT =================")
print("RPC_URL:", RPC_URL)
print("ROULETTE_CONTRACT:", ROULETTE_CONTRACT)
print("SWITCHBOARD_CONTRACT:", SWITCHBOARD_CONTRACT)
print("CHAIN_ID:", CHAIN_ID)

# ============================================================
# WEB3
# ============================================================
w3 = Web3(Web3.HTTPProvider(RPC_URL))
account = w3.eth.account.from_key(PRIVATE_KEY)

print("\n================ SIGNER =================")
print("Backend signer:", account.address)
print("Chain ID from node:", w3.eth.chain_id)

# ============================================================
# LOAD ABIs
# ============================================================
with open("contracts/roulette_abi.json") as f:
    roulette_abi = json.load(f)

with open("contracts/switchboard_abi.json") as f:
    switchboard_abi = json.load(f)

roulette = w3.eth.contract(ROULETTE_CONTRACT, abi=roulette_abi)
switchboard = w3.eth.contract(SWITCHBOARD_CONTRACT, abi=switchboard_abi)

# ============================================================
# GAS
# ============================================================
def gas():
    cfg = {
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 800_000,
        "gasPrice": w3.eth.gas_price,
    }
    print("\n[GAS]")
    pp.pprint(cfg)
    return cfg

# ============================================================
# DEBUG HELPERS
# ============================================================
def debug_roles():
    roles = {
        "backend_signer": account.address,
        "owner": roulette.functions.owner().call(),
        "controller": roulette.functions.controller().call(),
    }
    print("\n[ROLES]")
    pp.pprint(roles)
    return roles


def debug_round(round_id: int):
    r = roulette.functions.rounds(round_id).call()
    debug = {
        "id": r[0],
        "bettingClosesAt": r[1],
        "resolved": r[2],
        "randomRequested": r[3],
        "resultNumber": r[4],
        "randomnessId": Web3.to_hex(r[5]),
        "now": int(time.time()),
        "bettingStillOpen": int(time.time()) < r[1],
    }
    print("\n[ROUND STATE]")
    pp.pprint(debug)
    return debug


def debug_randomness(randomness_id: bytes):
    data = switchboard.functions.getRandomness(randomness_id).call()
    dbg = {
        "randId": Web3.to_hex(data[0]),
        "createdAt": data[1],
        "authority": data[2],
        "rollTimestamp": data[3],
        "minSettlementDelay": data[4],
        "oracle": data[5],
        "value": data[6],
        "settledAt": data[7],
        "now": int(time.time()),
        "readyByTime": data[3] + data[4],
    }
    print("\n[RANDOMNESS STATE]")
    pp.pprint(dbg)
    return dbg

# ============================================================
# 1️⃣ REQUEST RANDOMNESS
# ============================================================
@app.post("/request/{round_id}")
def request_randomness(round_id: int):
    print("\n================ /REQUEST =================")
    try:
        roles = debug_roles()
        round_state = debug_round(round_id)

        if roles["backend_signer"] not in [roles["owner"], roles["controller"]]:
            raise HTTPException(403, "Signer is NOT owner or controller")

        if round_state["randomRequested"]:
            raise HTTPException(400, "Randomness already requested")

        if round_state["bettingStillOpen"]:
            raise HTTPException(400, "Betting still open")

        print("\n[BUILD TX]")
        tx = roulette.functions.requestRoundRandomness(
            round_id, 10
        ).build_transaction(gas())
        pp.pprint(tx)

        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        print("\n[TX SENT]", tx_hash.hex())

        receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
        print("\n[RECEIPT]")
        pp.pprint(dict(receipt))

        if receipt.status == 0:
            raise HTTPException(500, "Request reverted")

        return {
            "status": "requested",
            "tx": tx_hash.hex(),
            "round": debug_round(round_id),
        }

    except Exception:
        traceback.print_exc()
        raise HTTPException(500, "Request failed — see logs")

# ============================================================
# 2️⃣ SETTLE RANDOMNESS (NODE SDK — CORRECT WAY)
# ============================================================
@app.post("/settle/{round_id}")
def settle_randomness(round_id: int):
    print("\n================ /SETTLE =================")
    try:
        round_state = debug_round(round_id)

        if int(round_state["randomnessId"], 16) == 0:
            raise HTTPException(400, "No randomnessId")

        randomness_id = Web3.to_bytes(hexstr=round_state["randomnessId"])
        rand_state = debug_randomness(randomness_id)

        if rand_state["now"] < rand_state["readyByTime"]:
            raise HTTPException(
                400,
                f"Settlement too early. Wait {rand_state['readyByTime'] - rand_state['now']}s",
            )

        # ---------- NODE RESOLVER ----------
        payload = {
            "chainId": CHAIN_ID,
            "randomnessId": round_state["randomnessId"],
            "oracle": rand_state["oracle"],
            "timestamp": rand_state["rollTimestamp"],
            "minStalenessSeconds": rand_state["minSettlementDelay"],
        }

        print("\n[NODE PAYLOAD]")
        pp.pprint(payload)

        proc = subprocess.run(
            ["node", "resolve.js"],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
        )

        print("\n[NODE STDOUT]")
        print(proc.stdout)
        print("\n[NODE STDERR]")
        print(proc.stderr)

        if proc.returncode != 0:
            raise HTTPException(500, "Node resolver failed")

                # --- FIX: extract JSON from Node output ---
        stdout_lines = proc.stdout.strip().splitlines()
        json_line = None

        for line in reversed(stdout_lines):
            if line.strip().startswith("{"):
                json_line = line.strip()
                break

        if not json_line:
            raise HTTPException(500, "No JSON output from Node resolver")

        node_data = json.loads(json_line)
        encoded = bytes.fromhex(node_data["encoded"][2:])

        print("\n[ENCODED RANDOMNESS OK]")

        update_fee = switchboard.functions.updateFee().call()
        print("\n[UPDATE FEE]", update_fee)

        tx_params = gas()
        tx_params["value"] = update_fee

        print("\n[BUILD SETTLE TX]")
        tx = switchboard.functions.settleRandomness(encoded).build_transaction(tx_params)
        pp.pprint(tx)

        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        print("\n[SETTLE TX SENT]", tx_hash.hex())

        receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
        print("\n[SETTLE RECEIPT]")
        pp.pprint(dict(receipt))

        if receipt.status == 0:
            raise HTTPException(500, "Settlement reverted")

        return {
            "status": "settled",
            "tx": tx_hash.hex(),
            "randomness": debug_randomness(randomness_id),
        }

    except Exception:
        traceback.print_exc()
        raise HTTPException(500, "Settlement failed — see logs")

# ============================================================
# 3️⃣ FINALIZE ROUND
# ============================================================
@app.post("/finalize/{round_id}")
def finalize_round(round_id: int):
    print("\n================ /FINALIZE =================")
    try:
        round_state = debug_round(round_id)

        print("\n[BUILD FINALIZE TX]")
        tx = roulette.functions.finalizeRoundFromRandomness(round_id).build_transaction(
            {**gas(), "gas": 400_000}
        )
        pp.pprint(tx)

        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        print("\n[FINALIZE TX SENT]", tx_hash.hex())

        receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
        print("\n[FINALIZE RECEIPT]")
        pp.pprint(dict(receipt))

        if receipt.status == 0:
            raise HTTPException(500, "Finalize reverted")

        return {
            "status": "finalized",
            "tx": tx_hash.hex(),
            "round": debug_round(round_id),
        }

    except Exception:
        traceback.print_exc()
        raise HTTPException(500, "Finalize failed — see logs")