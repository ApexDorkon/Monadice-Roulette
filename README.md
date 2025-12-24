# 🎲 Dice: VRF NFT-Based Roulette

**Dice** is a fully on-chain, verifiable roulette game where players wager **NFT Tickets** instead of standard tokens. By leveraging **Switchboard VRF** (Verifiable Random Function) and a hybrid **FastAPI/Node.js** settlement bridge, the platform ensures that every spin is mathematically fair and immune to house manipulation.



##  Key Architecture Highlights

* **NFT-as-Equity:** The contract operates an escrow system where whitelisted NFTs are used as the betting currency.
* **True Randomness:** Integrates Switchboard VRF to provide entropy that cannot be predicted by miners or the house.
* **Hybrid Backend Bridge:** A unique dual-language backend (Python + Node.js) that handles the complex Switchboard settlement proofs (Crossbar SDK) while maintaining a high-speed API for round management.
* **Campaign Whitelisting:** Allows the owner to whitelist specific NFT collections, enabling "Partnered Games" or "Community-specific" roulette events.

---

## 🏗 System Workflow

The project utilizes a 3-step settlement process to guarantee security and fairness:

1.  **Betting Phase:** Players call `placeBet()`. The contract pulls the NFT into escrow and records the `BetType`.
2.  **Request Phase:** Once the timer expires, the backend triggers `requestRoundRandomness()`.
3.  **Settlement Bridge:**
    * The Python **FastAPI** service detects a ready round.
    * It invokes the **Node.js** `resolve.js` worker to generate an encoded VRF proof via the Switchboard Crossbar SDK.
    * The backend submits this proof to the blockchain via `settleRandomness()`.
4.  **Finalization:** `finalizeRoundFromRandomness()` is called, the winning number is calculated, and NFTs are automatically routed to winners or the house vault.

---

## 🛠 Tech Stack

| Layer | Technology |
| :--- | :--- |
| **Smart Contracts** | Solidity 0.8.24, OpenZeppelin (ReentrancyGuard) |
| **Randomness Oracle**| Switchboard VRF (EVM Randomness) |
| **Backend API** | Python (FastAPI, Web3.py) |
| **Oracle Worker** | Node.js (Crossbar SDK) |
| **Chain Support** | Monad / EVM Compatible |

---

## 📜 Smart Contract Logic

### Supported Bet Types
The contract supports the full traditional European Roulette board (38 slots including 0 and 00):

| Bet Category | Description |
| :--- | :--- |
| **Inside Bets** | Straight (Single Number), Split, Street, Corner, Five Number, Line. |
| **Outside Bets** | Dozens (1st, 2nd, 3rd), Columns, Low/High, Red/Black, Odd/Even. |



### Security Measures
* **`nonReentrant`**: All state-changing functions are protected against reentrancy.
* **`onlyControllerOrOwner`**: Critical round-progression functions are gated to prevent unauthorized oracle manipulation.
* **Input Validation**: Strict validation ensures numbers are within the 0-37 range (37 representing `double zero`).

---

##  Getting Started

### 1. Backend Installation
```bash
# Install Python requirements
pip install fastapi web3 python-dotenv uvicorn

# Install Node.js requirements (for Crossbar SDK)
npm install @switchboard-xyz/common
```

### 2. Configuration (`.env`)
```bash
Create a `.env` file in the root directory and fill in your specific deployment details:

```env
# Network Settings
RPC_URL=your_rpc_endpoint
CHAIN_ID=143

# Contract Addresses
ROULETTE_CONTRACT=0x...
SWITCHBOARD_CONTRACT=0x...

# Authentication
PRIVATE_KEY=your_controller_wallet_key
```

### 3. Usage & Endpoints

The backend orchestrates the game state via these API endpoints:

POST /request/{round_id}: Initiates the VRF request once betting is closed.

POST /settle/{round_id}: Bridges the Switchboard proof from Node.js to the EVM.

POST /finalize/{round_id}: Resolves bets and executes NFT transfers.

### 4. Running the Automation
```bash
uvicorn main:app --host 0.0.0.0 --port 8000
```

## Repository Structure

* contracts/RouletteWL.sol: The core game engine and NFT escrow logic.

* main.py: FastAPI application for managing round transitions and gas management.

* resolve.js: Node.js script for generating Switchboard settlement proofs.

* contracts/roulette_abi.json: Pre-compiled ABI for easy integration.
