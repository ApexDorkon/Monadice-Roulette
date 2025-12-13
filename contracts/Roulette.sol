// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* ---------------------------------------------------------
   SWITCHBOARD EVM RANDOMNESS INTERFACE (UPDATED)
   contract 0xD3860E2C66cBd5c969Fa7343e6912Eff0416bA33
   que id 0xc9477bfb5ff1012859f336cf98725680e7705ba2abece17188cfb28ca66ca5b0
--------------------------------------------------------- */
interface ISwitchboard {
    // Preferred EVM randomness request per Switchboard docs
    function createRandomness(bytes32 randomnessId, uint64 minSettlementDelay)
        external
        returns (address oracle);

    function getRandomness(bytes32 randomnessId)
        external
        view
        returns (
            bytes32 randId,
            uint256 createdAt,
            address authority,
            uint256 rollTimestamp,
            uint64 minSettlementDelay,
            address oracle,
            uint256 value,
            uint256 settledAt
        );

    function isRandomnessReady(bytes32 randomnessId) external view returns (bool);

    function updateFee() external view returns (uint256);

    // Your backend calls this with Crossbar "encoded"
    function settleRandomness(bytes calldata encodedRandomness) external payable;
}

/* ---------------------------------------------------------
   MINIMAL NFT TICKET INTERFACE
--------------------------------------------------------- */
interface IBetTicket {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/* ---------------------------------------------------------
   ROULETTE CONTRACT WITH SWITCHBOARD VRF
--------------------------------------------------------- */
contract RouletteNFT {
    enum BetType {
        STRAIGHT, SPLIT, STREET, CORNER, FIVE_NUMBER, LINE,
        DOZEN, COLUMN, LOW, HIGH, RED, BLACK, ODD, EVEN
    }

    struct Round {
        uint256 id;
        uint64 bettingClosesAt;
        bool resolved;
        bool randomRequested;
        uint8 resultNumber;
        bytes32 randomnessId;
    }

    struct TicketBet {
        address player;
        address campaign;
        uint256 ticketId;
        BetType betType;
        uint8[] numbers;
        uint8 param;
        bool processed;
    }

    address public owner;
    address public controller;
    address public houseVault;

    ISwitchboard public switchboard;

    uint256 public currentRoundId;
    uint256 public nextBetId;

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => TicketBet) public bets;
    mapping(uint256 => uint256[]) public betsByRound;

    uint8 public constant DOUBLE_ZERO = 37;

    /* SWITCHBOARD QUEUE ID (kept for compatibility / config, not used by createRandomness) */
    bytes32 public queueId;

    /* EVENTS */
    event RoundCreated(uint256 indexed roundId, uint64 bettingClosesAt);
    event RoundRandomnessRequested(uint256 indexed roundId, bytes32 randomnessId);
    event RoundResolved(uint256 indexed roundId, uint8 resultNumber);

    event BetPlaced(
        uint256 indexed roundId,
        uint256 indexed betId,
        address indexed player,
        address campaign,
        uint256 ticketId,
        BetType betType
    );

    event BetWon(uint256 indexed roundId, uint256 indexed betId, address indexed player, address campaign, uint256 ticketId);
    event BetLost(uint256 indexed roundId, uint256 indexed betId, address indexed player, address campaign, uint256 ticketId);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyControllerOrOwner() {
        require(msg.sender == controller || msg.sender == owner, "Not allowed");
        _;
    }

    /* ---------------------------------------------------------
       CONSTRUCTOR
    --------------------------------------------------------- */
    constructor(
        address _switchboard,
        address _houseVault,
        address _controller,
        bytes32 _queueId
    ) {
        require(_switchboard != address(0), "switchboard=0");
        require(_houseVault != address(0), "houseVault=0");
        require(_controller != address(0), "controller=0");

        owner = msg.sender;
        switchboard = ISwitchboard(_switchboard);
        houseVault = _houseVault;
        controller = _controller;
        queueId = _queueId;

        _createNewRound(uint64(block.timestamp + 10));
    }

    /* ---------------------------------------------------------
       ROUND CREATION
    --------------------------------------------------------- */
    function createRound(uint64 bettingClosesAt) external onlyControllerOrOwner {
        _createNewRound(bettingClosesAt);
    }

    function _createNewRound(uint64 bettingClosesAt) internal {
        require(bettingClosesAt > block.timestamp, "close<=now");

        currentRoundId++;
        rounds[currentRoundId] = Round({
            id: currentRoundId,
            bettingClosesAt: bettingClosesAt,
            resolved: false,
            randomRequested: false,
            resultNumber: 0,
            randomnessId: bytes32(0)
        });

        emit RoundCreated(currentRoundId, bettingClosesAt);
    }

    /* ---------------------------------------------------------
       BET PLACEMENT
    --------------------------------------------------------- */
    function placeBet(
        address campaign,
        uint256 ticketId,
        BetType betType,
        uint8[] calldata numbers,
        uint8 param
    ) external returns (uint256 betId) {
        require(campaign != address(0), "campaign=0");

        Round storage r = rounds[currentRoundId];
        require(block.timestamp < r.bettingClosesAt, "betting closed");

        _validateBetInput(betType, numbers, param);

        IBetTicket(campaign).transferFrom(msg.sender, address(this), ticketId);

        betId = ++nextBetId;

        TicketBet storage b = bets[betId];
        b.player = msg.sender;
        b.campaign = campaign;
        b.ticketId = ticketId;
        b.betType = betType;
        b.param = param;

        if (numbers.length > 0) {
            b.numbers = new uint8[](numbers.length);
            for (uint256 i = 0; i < numbers.length; i++) {
                b.numbers[i] = numbers[i];
            }
        }

        betsByRound[currentRoundId].push(betId);

        emit BetPlaced(currentRoundId, betId, msg.sender, campaign, ticketId, betType);
    }

    /* ---------------------------------------------------------
       RANDOMNESS REQUEST (FIXED)
       - Not payable
       - No updateFee here
       - No low-level selector hack
       - Backend does settlement via settleRandomness(encoded)
    --------------------------------------------------------- */
    function requestRoundRandomness(uint256 roundId, uint64 minDelay)
        external
        onlyControllerOrOwner
    {
        Round storage r = rounds[roundId];
        require(r.id != 0, "invalid");
        require(block.timestamp >= r.bettingClosesAt, "betting open");
        require(!r.randomRequested, "already requested");

        // Deterministic enough + adds some entropy
        bytes32 randomnessId = keccak256(
            abi.encodePacked(address(this), roundId, block.timestamp, block.prevrandao)
        );

        // Switchboard request step (no ETH)
        switchboard.createRandomness(randomnessId, minDelay);

        r.randomRequested = true;
        r.randomnessId = randomnessId;

        emit RoundRandomnessRequested(roundId, randomnessId);
    }

    /* ---------------------------------------------------------
       FINALIZATION
    --------------------------------------------------------- */
    function finalizeRoundFromRandomness(uint256 roundId)
        external
        onlyControllerOrOwner
    {
        Round storage r = rounds[roundId];
        require(r.randomRequested, "not requested");
        require(!r.resolved, "resolved");

        (, , , , , , uint256 value, uint256 settledAt) =
            switchboard.getRandomness(r.randomnessId);

        require(settledAt != 0, "not settled");

        uint8 number = uint8(value % 38);
        _resolveRound(roundId, number);
    }

    function _resolveRound(uint256 roundId, uint8 number) internal {
        Round storage r = rounds[roundId];
        r.resolved = true;
        r.resultNumber = number;

        uint256[] storage ids = betsByRound[roundId];

        for (uint256 i = 0; i < ids.length; i++) {
            TicketBet storage b = bets[ids[i]];
            if (b.processed) continue;

            b.processed = true;
            bool win = _isWinningBet(b, number);

            if (win) {
                IBetTicket(b.campaign).transferFrom(address(this), b.player, b.ticketId);
                emit BetWon(roundId, ids[i], b.player, b.campaign, b.ticketId);
            } else {
                IBetTicket(b.campaign).transferFrom(address(this), houseVault, b.ticketId);
                emit BetLost(roundId, ids[i], b.player, b.campaign, b.ticketId);
            }
        }

        emit RoundResolved(roundId, number);
        _createNewRound(uint64(block.timestamp + 300));
    }

    /* ---------------------------------------------------------
       UTILITIES (unchanged)
    --------------------------------------------------------- */
    function _validateBetInput(
        BetType betType,
        uint8[] calldata numbers,
        uint8 param
    ) internal pure {
        if (
            betType == BetType.STRAIGHT ||
            betType == BetType.SPLIT ||
            betType == BetType.STREET ||
            betType == BetType.CORNER ||
            betType == BetType.FIVE_NUMBER ||
            betType == BetType.LINE
        ) require(numbers.length > 0);

        if (betType == BetType.STRAIGHT) require(numbers.length == 1);
        if (betType == BetType.SPLIT) require(numbers.length == 2);
        if (betType == BetType.STREET) require(numbers.length == 3);
        if (betType == BetType.CORNER) require(numbers.length == 4);
        if (betType == BetType.FIVE_NUMBER) require(numbers.length == 5);
        if (betType == BetType.LINE) require(numbers.length == 6);

        if (betType == BetType.DOZEN || betType == BetType.COLUMN)
            require(param >= 1 && param <= 3);
    }

    function _isWinningBet(TicketBet storage b, uint8 result)
        internal view returns (bool)
    {
        if (b.betType == BetType.STRAIGHT)
            return (result == b.numbers[0]);

        if (
            b.betType == BetType.SPLIT ||
            b.betType == BetType.STREET ||
            b.betType == BetType.CORNER ||
            b.betType == BetType.FIVE_NUMBER ||
            b.betType == BetType.LINE
        ) {
            for (uint i = 0; i < b.numbers.length; i++)
                if (b.numbers[i] == result) return true;
            return false;
        }

        if (b.betType == BetType.DOZEN) {
            if (result == 0 || result == DOUBLE_ZERO) return false;
            if (b.param == 1) return result <= 12;
            if (b.param == 2) return result <= 24;
            return result <= 36;
        }

        if (b.betType == BetType.COLUMN) {
            if (result == 0 || result == DOUBLE_ZERO) return false;
            return (((result - 1) % 3) + 1) == b.param;
        }

        if (b.betType == BetType.LOW) return (result >= 1 && result <= 18);
        if (b.betType == BetType.HIGH) return (result >= 19 && result <= 36);

        if (b.betType == BetType.RED) return _isRed(result);
        if (b.betType == BetType.BLACK) return !_isRed(result);

        if (b.betType == BetType.ODD)
            return (result % 2 == 1 && result != 0 && result != DOUBLE_ZERO);

        if (b.betType == BetType.EVEN)
            return (result % 2 == 0 && result != 0 && result != DOUBLE_ZERO);

        return false;
    }

    function _isRed(uint8 n) internal pure returns (bool) {
        return (
            n == 1 || n == 3 || n == 5 || n == 7 || n == 9 ||
            n == 12 || n == 14 || n == 16 || n == 18 ||
            n == 19 || n == 21 || n == 23 || n == 25 ||
            n == 27 || n == 30 || n == 32 || n == 34 || n == 36
        );
    }

    function emergencyWithdrawTicket(
        address campaign,
        uint256 tokenId,
        address to
    ) external onlyOwner {
        IBetTicket(campaign).transferFrom(address(this), to, tokenId);
    }
}