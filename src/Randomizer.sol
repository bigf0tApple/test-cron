// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Randomizer is Ownable {
    address public nftContract;
    uint256[] private _availableIds;
    uint256 private _nextIndex = 0;
    bool public paused = false;

    // P-GROUP POINTS (hard-coded, 50 groups P1-P50)
    uint256[] private _pGroupPoints = [
        42, 52, 54, 62, 66, 72, 78, 82, 90, 92,
        102, 112, 114, 122, 126, 132, 138, 142, 150, 152,
        162, 172, 174, 182, 186, 192, 198, 202, 210, 212,
        222, 232, 234, 242, 246, 252, 258, 262, 270, 272,
        282, 292, 294, 302, 306, 312, 318, 322, 330, 342
    ];

    // ID → P-group index (0-based)
    mapping(uint256 => uint256) private _idToGroup;

    // ID sequence hash verification
    bytes32 public idSequenceHash;
    bool public hashSet = false;

    uint256 public totalIdsSet = 0;

    event IdReturned(uint256 indexed tokenId);
    event IdBatchAdded(uint256 startIndex, uint256 count);
    event PGroupAdded(uint256 groupIndex, uint256[] ids);
    event SequenceHashSet(bytes32 hash);
    event NftContractUpdated(address indexed old, address indexed new_);

    constructor(address _nftContract) Ownable(msg.sender) {
        require(_nftContract != address(0), "Invalid NFT");
        nftContract = _nftContract;
    }

    function setNftContract(address _new) external onlyOwner {
        address old = nftContract;
        nftContract = _new;
        emit NftContractUpdated(old, _new);
    }

    function setIdSequenceHash(bytes32 _hash) external onlyOwner {
        require(!hashSet, "Hash already set");
        idSequenceHash = _hash;
        hashSet = true;
        emit SequenceHashSet(_hash);
    }

    // Upload shuffled IDs (batches ≤ 1000)
    // NOTE: Duplicate checking removed for gas optimization - data validated off-chain
    function addIdBatch(uint256[] calldata ids) external onlyOwner {
        require(!paused, "Paused");
        require(ids.length > 0 && ids.length <= 1000, "Batch 1-1000");
        require(totalIdsSet + ids.length <= 10000, "Too many");

        uint256 start = totalIdsSet;
        for (uint256 i = 0; i < ids.length; i++) {
            require(ids[i] >= 1 && ids[i] <= 10000, "ID must be 1-10000");
            _availableIds.push(ids[i]);
        }
        totalIdsSet += ids.length;
        emit IdBatchAdded(start, ids.length);

        // Validate hash if we have exactly 10000 and hash is set
        if (totalIdsSet == 10000 && hashSet) {
            require(keccak256(abi.encode(_availableIds)) == idSequenceHash, "ID hash mismatch");
        }
    }

    // Upload P-group IDs (any size)
    function addPGroup(uint256 groupIndex, uint256[] calldata ids) external onlyOwner {
        require(!paused, "Paused");
        require(groupIndex < _pGroupPoints.length, "Invalid group");
        require(ids.length > 0, "Empty");

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            require(id >= 1 && id <= 10000, "Bad ID");
            require(_idToGroup[id] == 0, "ID already assigned");
            _idToGroup[id] = groupIndex + 1; // 1-based
        }
        emit PGroupAdded(groupIndex, ids);
    }

    function getNextIdAndPoints() external returns (uint256 id, uint256 points) {
        require(msg.sender == nftContract, "Only NFT");
        require(!paused, "Paused");
        require(_nextIndex < _availableIds.length, "No IDs");
        require(totalIdsSet == 10000, "IDs incomplete");
        require(hashSet, "Hash not set");

        id = _availableIds[_nextIndex];
        uint256 group = _idToGroup[id];
        require(group > 0, "ID has no group");
        points = _pGroupPoints[group - 1];
        _nextIndex++;
        emit IdReturned(id);
        return (id, points);
    }

    function pause()   external onlyOwner { require(!paused); paused = true;  }
    function unpause() external onlyOwner { require(paused);  paused = false; }

    function remainingIds() external view returns (uint256) {
        return _availableIds.length - _nextIndex;
    }
}