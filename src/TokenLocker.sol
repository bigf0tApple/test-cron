// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TokenLocker (Vesting)
 * @notice Block-based vesting for team and spillage tokens
 * @dev Uses block numbers instead of timestamps for more predictable vesting
 *      Base/Ethereum: ~12 second blocks = ~216,000 blocks per 30 days
 */
contract TokenLocker is Ownable {
    IERC20 public immutable token;
    
    // ============ BLOCK TIMING ============
    // Base/Ethereum: ~12 second blocks (12.04s average)
    // 30 days = 30 * 24 * 60 * 60 = 2,592,000 seconds
    // 2,592,000 / 12 = 216,000 blocks per month
    uint256 public constant BLOCKS_PER_MONTH = 216_000;
    uint256 public constant CLIFF_BLOCKS = BLOCKS_PER_MONTH; // 1 month cliff
    uint256 public constant DECIMALS_MULTIPLIER = 10**18;

    struct Vesting {
        address beneficiary;
        uint256 totalAmount;
        uint256 startBlock;      // Block when vesting starts (after cliff)
        uint256 durationBlocks;  // Duration in blocks
        uint256 released;
    }

    Vesting[] public vestings;
    uint256 public deploymentBlock;

    // ============ EVENTS ============
    event VestingCreated(address indexed beneficiary, uint256 amount, uint256 durationBlocks);
    event TokensReleased(address indexed beneficiary, uint256 amount, uint256 vestingIndex);
    event BeneficiaryUpdated(uint256 indexed vestingIndex, address oldBeneficiary, address newBeneficiary);
    event EmergencyWithdraw(address indexed to, uint256 amount);

    constructor(address _tokenAddress) Ownable(msg.sender) {
        require(_tokenAddress != address(0), "Invalid token");
        token = IERC20(_tokenAddress);
        deploymentBlock = block.number;

        // Vesting starts after 1-month cliff
        uint256 startBlock = block.number + CLIFF_BLOCKS;

        // ============ TEAM WALLET: 330M total ============
        // 0x00aD851AbDe59d20DB72c7B2556e342CFca452E0
        address teamWallet = 0x00aD851AbDe59d20DB72c7B2556e342CFca452E0;
        
        // 132M over 10 months (13.2M per month)
        _createVesting(teamWallet, 132_000_000 * DECIMALS_MULTIPLIER, startBlock, 10 * BLOCKS_PER_MONTH);
        
        // 118.8M over 12 months (9.9M per month)
        _createVesting(teamWallet, 118_800_000 * DECIMALS_MULTIPLIER, startBlock, 12 * BLOCKS_PER_MONTH);
        
        // 79.2M over 16 months (4.95M per month)
        _createVesting(teamWallet, 79_200_000 * DECIMALS_MULTIPLIER, startBlock, 16 * BLOCKS_PER_MONTH);

        // ============ SPILLAGE WALLET: 52M total ============
        // 0x009A4d69A28F4e8f0B10D09FBD1c4Cf084aCe5B8
        address spillageWallet = 0x009A4d69A28F4e8f0B10D09FBD1c4Cf084aCe5B8;
        
        // 20.8M over 10 months (2.08M per month)
        _createVesting(spillageWallet, 20_800_000 * DECIMALS_MULTIPLIER, startBlock, 10 * BLOCKS_PER_MONTH);
        
        // 18.72M over 12 months (1.56M per month)
        _createVesting(spillageWallet, 18_720_000 * DECIMALS_MULTIPLIER, startBlock, 12 * BLOCKS_PER_MONTH);
        
        // 12.48M over 16 months (0.78M per month)
        _createVesting(spillageWallet, 12_480_000 * DECIMALS_MULTIPLIER, startBlock, 16 * BLOCKS_PER_MONTH);
    }

    function _createVesting(
        address beneficiary, 
        uint256 amount, 
        uint256 startBlock, 
        uint256 durationBlocks
    ) internal {
        require(beneficiary != address(0), "Invalid beneficiary");
        require(amount > 0, "Invalid amount");
        require(durationBlocks > 0, "Invalid duration");

        vestings.push(Vesting({
            beneficiary: beneficiary,
            totalAmount: amount,
            startBlock: startBlock,
            durationBlocks: durationBlocks,
            released: 0
        }));
        
        emit VestingCreated(beneficiary, amount, durationBlocks);
    }

    // ============ VIEW FUNCTIONS ============

    function getVestingCount() external view returns (uint256) {
        return vestings.length;
    }

    function getVestingInfo(uint256 index) external view returns (
        address beneficiary,
        uint256 totalAmount,
        uint256 startBlock,
        uint256 durationBlocks,
        uint256 released,
        uint256 releasable
    ) {
        require(index < vestings.length, "Invalid index");
        Vesting storage v = vestings[index];
        return (
            v.beneficiary,
            v.totalAmount,
            v.startBlock,
            v.durationBlocks,
            v.released,
            releasableAmount(index)
        );
    }

    function releasableAmount(uint256 index) public view returns (uint256) {
        require(index < vestings.length, "Invalid index");
        Vesting storage vesting = vestings[index];
        
        // Still in cliff period
        if (block.number < vesting.startBlock) {
            return 0;
        }

        uint256 elapsedBlocks = block.number - vesting.startBlock;
        uint256 vestedAmount;
        
        if (elapsedBlocks >= vesting.durationBlocks) {
            // Fully vested
            vestedAmount = vesting.totalAmount;
        } else {
            // Proportional vesting
            vestedAmount = (vesting.totalAmount * elapsedBlocks) / vesting.durationBlocks;
        }

        return vestedAmount - vesting.released;
    }

    function getTotalReleasable(address beneficiary) external view returns (uint256 total) {
        for (uint256 i = 0; i < vestings.length; i++) {
            if (vestings[i].beneficiary == beneficiary) {
                total += releasableAmount(i);
            }
        }
    }

    function getBlocksUntilCliffEnd() external view returns (uint256) {
        uint256 cliffEndBlock = deploymentBlock + CLIFF_BLOCKS;
        if (block.number >= cliffEndBlock) {
            return 0;
        }
        return cliffEndBlock - block.number;
    }

    function getBlocksUntilNextUnlock(uint256 index) external view returns (uint256) {
        require(index < vestings.length, "Invalid index");
        Vesting storage vesting = vestings[index];
        
        if (block.number < vesting.startBlock) {
            return vesting.startBlock - block.number;
        }
        
        if (vesting.released >= vesting.totalAmount) {
            return 0; // Fully released
        }
        
        // Vesting is linear, so next unlock is essentially the next block
        return 1;
    }

    // ============ RELEASE FUNCTIONS ============

    function release(uint256 index) external {
        require(index < vestings.length, "Invalid index");
        Vesting storage vesting = vestings[index];
        require(msg.sender == vesting.beneficiary, "Only beneficiary");
        
        uint256 unreleased = releasableAmount(index);
        require(unreleased > 0, "No tokens to release");

        vesting.released += unreleased;
        require(token.transfer(vesting.beneficiary, unreleased), "Transfer failed");

        emit TokensReleased(vesting.beneficiary, unreleased, index);
    }

    function releaseAll() external {
        uint256 totalReleased = 0;
        
        for (uint256 i = 0; i < vestings.length; i++) {
            if (vestings[i].beneficiary == msg.sender) {
                uint256 unreleased = releasableAmount(i);
                if (unreleased > 0) {
                    vestings[i].released += unreleased;
                    totalReleased += unreleased;
                    emit TokensReleased(msg.sender, unreleased, i);
                }
            }
        }
        
        require(totalReleased > 0, "No tokens to release");
        require(token.transfer(msg.sender, totalReleased), "Transfer failed");
    }

    // ============ ADMIN FUNCTIONS ============

    function updateBeneficiary(uint256 index, address newBeneficiary) external onlyOwner {
        require(index < vestings.length, "Invalid index");
        require(newBeneficiary != address(0), "Invalid beneficiary");
        
        address oldBeneficiary = vestings[index].beneficiary;
        vestings[index].beneficiary = newBeneficiary;
        
        emit BeneficiaryUpdated(index, oldBeneficiary, newBeneficiary);
    }

    function emergencyWithdraw(address to) external onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No tokens");
        require(token.transfer(to, balance), "Transfer failed");
        emit EmergencyWithdraw(to, balance);
    }

    // ============ SUMMARY FUNCTIONS ============

    function getVestingSummary() external view returns (
        uint256 totalLocked,
        uint256 totalReleased,
        uint256 totalReleasable
    ) {
        for (uint256 i = 0; i < vestings.length; i++) {
            totalLocked += vestings[i].totalAmount;
            totalReleased += vestings[i].released;
            totalReleasable += releasableAmount(i);
        }
    }

    function getBeneficiarySummary(address beneficiary) external view returns (
        uint256 totalAllocated,
        uint256 totalReleased,
        uint256 totalReleasable
    ) {
        for (uint256 i = 0; i < vestings.length; i++) {
            if (vestings[i].beneficiary == beneficiary) {
                totalAllocated += vestings[i].totalAmount;
                totalReleased += vestings[i].released;
                totalReleasable += releasableAmount(i);
            }
        }
    }
}