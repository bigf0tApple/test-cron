// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title TokenTracker
 * @notice Tracks token holder balances for reward distribution
 * @dev Uses non-tradable ERC20 tokens to track balances, with exclusions for system addresses
 */
contract TokenTracker is ERC20, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ ADDRESSES ============
    address public mainTokenContract;
    address public rewardsContract;

    // ============ HOLDERS ============
    EnumerableSet.AddressSet internal holders;

    // ============ CONFIGURATION ============
    uint256 public minHoldAmount = 1000 * 10**18; // 1000 tokens minimum

    // ============ EXCLUSIONS ============
    mapping(address => bool) public excludedAddresses;

    // ============ SNAPSHOTS ============
    mapping(uint256 => uint256) public cycleToTotalBalances;
    mapping(uint256 => mapping(address => uint256)) public cycleToHolderBalances;

    // ============ EVENTS ============
    event BalanceUpdated(address indexed holder, uint256 newBalance);
    event SnapshotTaken(uint256 indexed cycleId, uint256 totalBalances);
    event AddressExcluded(address indexed addr, bool excluded);
    event MainTokenContractUpdated(address indexed oldAddr, address indexed newAddr);
    event RewardsContractUpdated(address indexed oldAddr, address indexed newAddr);
    event MinHoldAmountUpdated(uint256 oldAmount, uint256 newAmount);

    constructor(
        address _mainTokenContract,
        string memory _name,
        string memory _symbol,
        address[] memory _excludedAddresses
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        _setMainTokenContract(_mainTokenContract);
        
        // Set initial exclusions
        for (uint256 i = 0; i < _excludedAddresses.length; i++) {
            if (_excludedAddresses[i] != address(0)) {
                excludedAddresses[_excludedAddresses[i]] = true;
                emit AddressExcluded(_excludedAddresses[i], true);
            }
        }
    }

    // ============ INTERNAL SETTERS ============

    function _setMainTokenContract(address _mainTokenContract) internal {
        require(_mainTokenContract != address(0), "Invalid main token contract");
        mainTokenContract = _mainTokenContract;
    }

    // ============ ADMIN FUNCTIONS ============

    function setMainTokenContract(address _newMainTokenContract) external onlyOwner {
        address old = mainTokenContract;
        _setMainTokenContract(_newMainTokenContract);
        emit MainTokenContractUpdated(old, _newMainTokenContract);
    }

    function setRewardsContract(address _rewardsContract) external onlyOwner {
        require(_rewardsContract != address(0), "Invalid rewards contract");
        address old = rewardsContract;
        rewardsContract = _rewardsContract;
        emit RewardsContractUpdated(old, _rewardsContract);
    }

    function setMinHoldAmount(uint256 amount) external onlyOwner {
        uint256 old = minHoldAmount;
        minHoldAmount = amount;
        emit MinHoldAmountUpdated(old, amount);
    }

    function setExcludedAddress(address addr, bool exclude) external onlyOwner {
        excludedAddresses[addr] = exclude;
        emit AddressExcluded(addr, exclude);
        
        // Remove from holders if excluded and currently tracked
        if (exclude && holders.contains(addr)) {
            holders.remove(addr);
        }
    }

    /**
     * @notice Bulk exclude addresses (for setup)
     */
    function excludeMultipleAddresses(address[] calldata addresses) external onlyOwner {
        for (uint256 i = 0; i < addresses.length; i++) {
            if (addresses[i] != address(0)) {
                excludedAddresses[addresses[i]] = true;
                emit AddressExcluded(addresses[i], true);
                
                if (holders.contains(addresses[i])) {
                    holders.remove(addresses[i]);
                }
            }
        }
    }

    // ============ MODIFIERS ============

    modifier onlyMainTokenContract() {
        require(msg.sender == mainTokenContract, "Only main token contract");
        _;
    }

    // ============ BALANCE UPDATES ============

    /**
     * @notice Called by main token contract on transfers
     * @param account The account whose balance changed
     * @param newBalance The new balance of the account
     */
    function setBalance(address account, uint256 newBalance) external onlyMainTokenContract {
        // Skip excluded addresses
        if (excludedAddresses[account]) {
            return;
        }

        uint256 currentBalance = balanceOf(account);

        if (newBalance > currentBalance) {
            uint256 mintAmount = newBalance - currentBalance;
            _mint(account, mintAmount);
        } else if (newBalance < currentBalance) {
            uint256 burnAmount = currentBalance - newBalance;
            _burn(account, burnAmount);
        }

        // Update holders set
        uint256 updatedBalance = balanceOf(account);
        emit BalanceUpdated(account, updatedBalance);

        if (updatedBalance < minHoldAmount) {
            holders.remove(account);
        } else {
            holders.add(account);
        }
    }

    // ============ SNAPSHOT ============

    function takeSnapshot(uint256 cycleId) external {
        require(msg.sender == rewardsContract || msg.sender == owner(), "Only rewards or owner");
        require(cycleToTotalBalances[cycleId] == 0, "Snapshot already taken");

        uint256 total = 0;
        uint256 holderLen = holders.length();
        
        for (uint256 i = 0; i < holderLen; i++) {
            address holder = holders.at(i);
            if (excludedAddresses[holder]) continue;
            
            uint256 bal = balanceOf(holder);
            if (bal >= minHoldAmount) {
                cycleToHolderBalances[cycleId][holder] = bal;
                total += bal;
            }
        }
        
        cycleToTotalBalances[cycleId] = total;
        emit SnapshotTaken(cycleId, total);
    }

    // ============ VIEW FUNCTIONS ============

    function getNumberOfTokenHolders() external view returns (uint256) {
        return holders.length();
    }

    function holderAt(uint256 index) external view returns (address) {
        return holders.at(index);
    }

    function minimumTokenBalanceForDividends() external view returns (uint256) {
        return minHoldAmount;
    }

    function isExcluded(address account) external view returns (bool) {
        return excludedAddresses[account];
    }

    function isEligibleHolder(address account) external view returns (bool) {
        if (excludedAddresses[account]) return false;
        return balanceOf(account) >= minHoldAmount;
    }

    function getAllHolders() external view returns (address[] memory) {
        uint256 len = holders.length();
        address[] memory result = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = holders.at(i);
        }
        return result;
    }

    function getHolderBalance(address holder) external view returns (uint256) {
        return balanceOf(holder);
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