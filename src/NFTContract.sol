// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";


interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IRandomizer {
    function getNextIdAndPoints() external returns (uint256 id, uint256 points);
}

interface IUniswapV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function WETH() external pure returns (address);
}

interface INFTTracker {
    function updateBalance(address from, address to, uint256 tokenId, uint256 points) external;
}

/**
 * @title NFT Contract (V2 Compatible)
 * @notice ERC721 NFT with presale and post-presale minting
 * @dev Presale: $100 in USDC (frontend can swap via 0x). Post-presale: 0.01% of market cap in TOKEN
 */
contract NFTContract is ERC721Royalty, Ownable, ReentrancyGuard {
    using Strings for uint256;

    // ============ CONSTANTS ============
    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant MAX_PER_MINT = 5;
    uint256 public constant PRESALE_MAX = 250;
    uint256 public constant PRESALE_PRICE_USD = 100e18; // $100
    uint96 public constant ROYALTY_BPS = 162; // 1.62% ≈ 1.618% (ERC2981 uses 10000 divisor)

    // ============ ADJUSTABLE ============
    uint256 public maxWallet = 5;

    // ============ PRESALE STATE ============
    bool public presaleActive = true;
    bool public postPresaleActive = false;

    // ============ ADDRESSES ============
    address public erc20Token; // Main TOKEN
    address public usdc; // USDC on Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (6 decimals)
    address public nftTracker;
    address public randomizer;
    address public nftMintFund; // Where presale funds go
    
    // ============ CIRCULATING SUPPLY EXCLUSIONS ============
    address public tokenLocker; // Team vesting contract
    address public constant DEAD_WALLET = 0x000000000000000000000000000000000000dEaD;

    // ============ STATE ============
    uint256 public mintedCount;
    string public baseURI;
    bool public paused = false;

    mapping(uint256 => uint256) public pointsMintedCount;
    mapping(uint256 => uint256) public tokenIdToPoints;
    mapping(uint256 => bool) private _minted;
    mapping(address => uint256) public walletMintedCount;



    // ============ INTERFACES ============
    IRandomizer private _randomizerContract;
    IERC20 private _erc20Contract;

    // ============ EVENTS ============
    event Minted(address indexed to, uint256 indexed tokenId, uint256 points);
    event OwnerMinted(address indexed to, uint256 quantity);
    event MintingPaused();
    event MintingResumed();
    event EthWithdrawn(address indexed to, uint256 amount);
    event Erc20Withdrawn(address indexed to, uint256 amount);
    event RandomizerUpdated(address indexed oldRandomizer, address indexed newRandomizer);
    event NftTrackerUpdated(address indexed oldTracker, address indexed newTracker);
    event MaxWalletUpdated(uint256 newMax);
    event PresaleEnded();
    event PostPresaleStarted();


    constructor(
        string memory _initialBaseURI,
        address _erc20Token,
        address _randomizer,
        address _nftTracker,
        address _usdc,
        address _nftMintFund
    ) ERC721("773me Drops", "773DROPS") Ownable(msg.sender) {
        require(_randomizer != address(0), "Invalid randomizer");
        require(_nftMintFund != address(0), "Invalid mint fund");

        baseURI = _initialBaseURI;
        erc20Token = _erc20Token;
        usdc = _usdc;
        nftTracker = _nftTracker;
        nftMintFund = _nftMintFund;
        
        if (_erc20Token != address(0)) {
            _erc20Contract = IERC20(_erc20Token);
        }
        _setRandomizer(_randomizer);
        
        // Set 1.618% royalty to NFT_MINT_FUND
        _setDefaultRoyalty(_nftMintFund, ROYALTY_BPS);
    }

    // ============ OWNER FUNCTIONS ============

    function setErc20Token(address _newErc20) external onlyOwner {
        require(_newErc20 != address(0), "Invalid ERC20");
        erc20Token = _newErc20;
        _erc20Contract = IERC20(_newErc20);
    }

    function setTokenLocker(address _locker) external onlyOwner {
        tokenLocker = _locker;
    }

    function setUsdcToken(address _usdc) external onlyOwner {
        usdc = _usdc;
    }

    function setNftMintFund(address _fund) external onlyOwner {
        require(_fund != address(0), "Invalid fund");
        nftMintFund = _fund;
    }

    function ownerMint(address to, uint256 quantity) external onlyOwner nonReentrant {
        require(quantity > 0, "Quantity > 0");
        require(mintedCount + quantity <= MAX_SUPPLY, "Exceeds max supply");
        require(to != address(0), "Invalid address");

        _mintBatch(to, quantity);
        emit OwnerMinted(to, quantity);
    }

    function setMaxWallet(uint256 _newMax) external onlyOwner {
        maxWallet = _newMax;
        emit MaxWalletUpdated(_newMax);
    }

    function setRandomizer(address _newRandomizer) external onlyOwner {
        require(_newRandomizer != address(0), "Invalid randomizer");
        address old = randomizer;
        _setRandomizer(_newRandomizer);
        emit RandomizerUpdated(old, _newRandomizer);
    }

    function _setRandomizer(address _randomizer) private {
        randomizer = _randomizer;
        _randomizerContract = IRandomizer(_randomizer);
    }

    function setNftTracker(address _newTracker) external onlyOwner {
        address old = nftTracker;
        nftTracker = _newTracker;
        emit NftTrackerUpdated(old, _newTracker);
    }

    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        baseURI = _newBaseURI;
    }

    function pause() external onlyOwner {
        paused = true;
        emit MintingPaused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit MintingResumed();
    }

    function withdrawEth() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH");
        payable(owner()).transfer(balance);
        emit EthWithdrawn(owner(), balance);
    }

    function withdrawErc20(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens");
        require(IERC20(token).transfer(owner(), balance), "Transfer failed");
        emit Erc20Withdrawn(owner(), balance);
    }


    /**
     * @notice Mint NFT during presale with USDC at $100
     * @dev Frontend can swap any asset to USDC via 0x before calling this
     */
    function mintPresaleUSDC(address to, uint256 quantity) external nonReentrant {
        require(!paused, "Minting paused");
        require(presaleActive, "Presale not active");
        require(quantity > 0 && quantity <= MAX_PER_MINT, "Invalid quantity");
        require(mintedCount + quantity <= PRESALE_MAX, "Exceeds presale max");
        require(walletMintedCount[to] + quantity <= maxWallet, "Exceeds max per wallet");
        require(usdc != address(0), "USDC not set");
        require(nftMintFund != address(0), "Mint fund not set");

        uint256 totalUSDCCost = (100 * 1e6) * quantity;
        require(IERC20(usdc).transferFrom(msg.sender, nftMintFund, totalUSDCCost), "USDC transfer failed");

        _mintBatch(to, quantity);
        walletMintedCount[to] += quantity;
    }


    // ============ POST-PRESALE FUNCTIONS ============

    function endPresale() external onlyOwner {
        require(presaleActive, "Presale already ended");
        presaleActive = false;
        postPresaleActive = true;
        emit PresaleEnded();
        emit PostPresaleStarted();
    }



    /**
     * @notice Get post-presale mint price in TOKEN
     * @return tokenAmount Amount of TOKEN needed per NFT = Circulating Supply / 10,000
     */
    function getMintPriceInToken() public view returns (uint256) {
        require(erc20Token != address(0), "Token not set");
        
        // Get circulating supply (total - dead - locked team tokens)
        uint256 totalSupply = IERC20(erc20Token).totalSupply();
        uint256 deadBalance = IERC20(erc20Token).balanceOf(DEAD_WALLET);
        uint256 lockerBalance = tokenLocker != address(0) 
            ? IERC20(erc20Token).balanceOf(tokenLocker) 
            : 0;
        
        uint256 circulatingSupply = totalSupply - deadBalance - lockerBalance;
        
        // Price = Circulating Supply / 10,000 (0.01% of circulating)
        return circulatingSupply / 10000;
    }



    // Keep old name for compatibility, now returns TOKEN amount
    function getPostPresaleMintPrice() public view returns (uint256) {
        return getMintPriceInToken();
    }





    /**
     * @notice Mint NFT post-presale with TOKEN (simplest - no swap needed)
     */
    function mintWithToken(address to, uint256 quantity) external nonReentrant {
        require(!paused, "Minting paused");
        require(postPresaleActive, "Post-presale not active");
        require(quantity > 0 && quantity <= MAX_PER_MINT, "Invalid quantity");
        require(mintedCount + quantity <= MAX_SUPPLY, "Exceeds max supply");
        require(walletMintedCount[to] + quantity <= maxWallet, "Exceeds max per wallet");
        require(address(_erc20Contract) != address(0), "Token not set");

        // Price in TOKEN = Circulating Supply / 10,000
        uint256 tokenPricePerNFT = getMintPriceInToken();
        uint256 totalTokenCost = tokenPricePerNFT * quantity;

        require(_erc20Contract.allowance(msg.sender, address(this)) >= totalTokenCost, "Insufficient allowance");
        require(_erc20Contract.balanceOf(msg.sender) >= totalTokenCost, "Insufficient balance");
        require(_erc20Contract.transferFrom(msg.sender, address(this), totalTokenCost), "Transfer failed");

        _mintBatch(to, quantity);
        walletMintedCount[to] += quantity;
    }

    /**
     * @notice Get post-presale cost estimates for frontend
     * @dev Only returns token cost - ETH/SOL estimates require oracle integration
     */
    function getPostPresaleCost(uint256 quantity) external view returns (
        uint256 tokenCost,
        uint256 ethCost,
        uint256 solCost
    ) {
        tokenCost = getMintPriceInToken() * quantity;
        // ETH and SOL costs require oracle integration - return 0 for now
        // Frontend can calculate from token price and pool ratios
        ethCost = 0;
        solCost = 0;
    }

    // ============ INTERNAL MINT LOGIC ============

    function _mintBatch(address to, uint256 quantity) private {
        for (uint256 i = 0; i < quantity; i++) {
            (uint256 randomId, uint256 points) = _randomizerContract.getNextIdAndPoints();
            require(!_minted[randomId], "Token already minted");
            
            _minted[randomId] = true;
            tokenIdToPoints[randomId] = points;
            pointsMintedCount[points]++;
            mintedCount++;

            _safeMint(to, randomId);

            if (nftTracker != address(0)) {
                INFTTracker(nftTracker).updateBalance(address(0), to, randomId, points);
            }
            emit Minted(to, randomId, points);
        }

        // Auto-pause presale at PRESALE_MAX
        if (presaleActive && mintedCount >= PRESALE_MAX) {
            presaleActive = false;
            postPresaleActive = true;
            emit PresaleEnded();
            emit PostPresaleStarted();
        }

        // Piggyback: Flush any accumulated tokens to nftMintFund
        _flushTokensToMintFund();
    }

    /**
     * @notice Piggyback flush: Forward any tokens in this contract to nftMintFund
     * @dev Called automatically on each mint to prevent token accumulation
     */
    function _flushTokensToMintFund() internal {
        if (address(_erc20Contract) == address(0)) return;
        
        uint256 balance = _erc20Contract.balanceOf(address(this));
        if (balance > 0 && nftMintFund != address(0)) {
            _erc20Contract.transfer(nftMintFund, balance);
            emit TokensFlushed(nftMintFund, balance);
        }
    }

    event TokensFlushed(address indexed to, uint256 amount);

    // ============ TRANSFER HOOK ============

    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        address previousOwner = super._update(to, tokenId, auth);

        // Update tracker on transfer/burn (skip on mint - handled in _mintBatch)
        if (from != address(0) && nftTracker != address(0)) {
            uint256 points = tokenIdToPoints[tokenId];
            INFTTracker(nftTracker).updateBalance(from, to, tokenId, points);
        }

        return previousOwner;
    }

    // ============ METADATA ============

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Nonexistent token");
        return string(abi.encodePacked(_baseURI(), tokenId.toString(), ".json"));
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Royalty) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}
