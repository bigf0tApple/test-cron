// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IPyth
 * @notice PYTH Network oracle interface for Base mainnet
 * @dev PYTH on Base: 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a
 */
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint publishTime;
    }

    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory price);
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
    function getPrice(bytes32 id) external view returns (Price memory price);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint feeAmount);
}
