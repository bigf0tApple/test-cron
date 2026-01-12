// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title NFTTracker
 * @notice Tracks NFT holder points for reward distribution
 * @dev Each NFT has points (max 342), tracked via non-tradable ERC20-like tokens
 */
contract NFTTracker is ERC20, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ CONSTANTS ============
    uint256 public constant MAX_POINTS_PER_NFT = 342;

    // ============ ADDRESSES ============
    address public nftContract;
    address public rewardsContract;

    // ============ POINTS TRACKING ============
    mapping(uint256 => uint256) public pointsPerTokenId;

    // ============ HOLDERS ============
    EnumerableSet.AddressSet internal holders;
    uint256 public minHoldAmount = 1;

    // ============ SNAPSHOTS ============
    mapping(uint256 => uint256) public cycleToTotalPoints;
    mapping(uint256 => mapping(address => uint256)) public cycleToHolderPoints;

    // ============ EVENTS ============
    event PointsUpdated(uint256 indexed tokenId, uint256 points);
    event BalanceUpdated(address indexed holder, uint256 newBalance);
    event SnapshotTaken(uint256 indexed cycleId, uint256 totalPoints);
    event NFTContractUpdated(address indexed oldContract, address indexed newContract);
    event RewardsContractUpdated(address indexed oldContract, address indexed newContract);

    modifier onlyNftContract() {
        require(msg.sender == nftContract, "Caller is not NFT contract");
        _;
    }

    constructor() ERC20("NFTDividendToken", "NFTDIV") Ownable(msg.sender) {}

    // ============ ADMIN FUNCTIONS ============

    function setRewardsContract(address _rewardsContract) external onlyOwner {
        require(_rewardsContract != address(0), "Invalid rewards contract");
        address old = rewardsContract;
        rewardsContract = _rewardsContract;
        emit RewardsContractUpdated(old, _rewardsContract);
    }

    function setNFTContract(address _nftContract) external onlyOwner {
        require(_nftContract != address(0), "Invalid NFT contract");
        address old = nftContract;
        nftContract = _nftContract;
        emit NFTContractUpdated(old, _nftContract);
    }

    function setMinHoldAmount(uint256 amount) external onlyOwner {
        minHoldAmount = amount;
    }

    // ============ DECIMALS ============

    function decimals() public view virtual override returns (uint8) {
        return 0;
    }

    // ============ BALANCE UPDATES ============

    /**
     * @notice Called by NFT contract on mint/transfer/burn
     * @param from Previous owner (address(0) for mint)
     * @param to New owner (address(0) for burn)
     * @param tokenId The NFT token ID
     * @param points Points assigned to this NFT
     */
    function updateBalance(address from, address to, uint256 tokenId, uint256 points) external onlyNftContract {
        uint256 oldPoints = pointsPerTokenId[tokenId];

        // Burn tokens from previous holder (if transfer or burn)
        if (from != address(0) && oldPoints > 0) {
            uint256 currentBalance = balanceOf(from);
            if (currentBalance >= oldPoints) {
                _burn(from, oldPoints);
            }
        }

        // Update points for tokenId
        pointsPerTokenId[tokenId] = points;
        emit PointsUpdated(tokenId, points);

        // Mint tokens to new holder (if mint or transfer)
        if (to != address(0)) {
            _mint(to, points);
        }

        // Update holders set
        if (from != address(0)) {
            uint256 fromBalance = balanceOf(from);
            emit BalanceUpdated(from, fromBalance);
            if (fromBalance < minHoldAmount) {
                holders.remove(from);
            }
        }
        if (to != address(0)) {
            uint256 toBalance = balanceOf(to);
            emit BalanceUpdated(to, toBalance);
            if (toBalance >= minHoldAmount) {
                holders.add(to);
            }
        }
    }

    // ============ SNAPSHOT ============

    function takeSnapshot(uint256 cycleId) external {
        require(msg.sender == rewardsContract || msg.sender == owner(), "Only rewards or owner");
        require(cycleToTotalPoints[cycleId] == 0, "Snapshot already taken");

        uint256 total = 0;
        uint256 holderLen = holders.length();
        
        for (uint256 i = 0; i < holderLen; i++) {
            address holder = holders.at(i);
            uint256 points = balanceOf(holder);
            if (points >= minHoldAmount) {
                cycleToHolderPoints[cycleId][holder] = points;
                total += points;
            }
        }
        
        cycleToTotalPoints[cycleId] = total;
        emit SnapshotTaken(cycleId, total);
    }

    // ============ VIEW FUNCTIONS ============

    function holderCount() external view returns (uint256) {
        return holders.length();
    }

    function holderAt(uint256 index) external view returns (address) {
        return holders.at(index);
    }

    /**
     * @notice Get eligible points for a holder (capped at MAX_POINTS_PER_NFT per NFT)
     * @dev Points are already capped at mint time in NFT contract
     */
    function getEligiblePoints(address holder) external view returns (uint256) {
        return balanceOf(holder);
    }

    /**
     * @notice Get theoretical maximum points if all NFTs had max points
     * @return Total max points (holderCount * MAX_POINTS_PER_NFT is approximate)
     */
    function getTotalMaxPoints() external view returns (uint256) {
        return holders.length() * MAX_POINTS_PER_NFT;
    }

    /**
     * @notice Get the excess points that should be swept (theoretical max - actual)
     */
    function getExcessPoints() external view returns (uint256) {
        uint256 theoretical = holders.length() * MAX_POINTS_PER_NFT;
        uint256 actual = totalSupply();
        if (actual >= theoretical) return 0;
        return theoretical - actual;
    }

    /**
     * @notice Check if holder meets minimum requirements
     */
    function isEligibleHolder(address holder) external view returns (bool) {
        return balanceOf(holder) >= minHoldAmount;
    }

    /**
     * @notice Get all holder addresses
     */
    function getAllHolders() external view returns (address[] memory) {
        uint256 len = holders.length();
        address[] memory result = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = holders.at(i);
        }
        return result;
    }

    // ============ TRANSFER RESTRICTIONS ============

    function transfer(address, uint256) public pure override returns (bool) {
        revert("Tokens are non-tradable");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("Tokens are non-tradable");
    }

    // ============ OWNER FUNCTIONS ============

    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }
}