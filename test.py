from web3 import Web3
import os, json
from dotenv import load_dotenv

load_dotenv()

w3 = Web3(Web3.HTTPProvider(os.getenv("RPC_URL")))
addr = os.getenv("SWITCHBOARD_CONTRACT")

abi = [
    {
        "inputs": [],
        "name": "updateFee",
        "outputs": [
            {"internalType": "uint256", "name": "", "type": "uint256"}
        ],
        "stateMutability": "view",
        "type": "function"
    }
]

sb = w3.eth.contract(address=addr, abi=abi)
print("Fee:", sb.functions.updateFee().call())
