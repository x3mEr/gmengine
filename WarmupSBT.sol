// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract WarmupSBT is ERC721, Ownable, Pausable, ReentrancyGuard {
    error NonTransferable();

    uint256 public mintPriceWei;
    uint256 public maxSupply;    // 0 = unlimited
    uint256 public maxPerWallet; // 0 = unlimited
    uint24 public totalMinted = 0;
    string public baseTokenURI;
    mapping(address => uint24) public mintedPerWallet;
    address payable public collector;

    event Minted(address indexed minter, uint24 indexed tokenId, uint256 pricePaid);
    event OwnerMinted(address indexed recipient, uint24 indexed tokenId);
    event PriceChanged(uint256 oldMintPriceWei, uint256 newMintPriceWei);
    event BaseTokenUriChanged(string oldBaseTokenURI, string newBaseTokenURI);
    event MintPaused();
    event MintUnpaused();

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseTokenURI,
        uint256 _mintPriceWei,
        address payable _collector,
        uint256 _maxSupply,
        uint256 _maxPerWallet
    )
        ERC721(_name, _symbol)
        Ownable(msg.sender)
    {
        require(bytes(_baseTokenURI).length > 0, "Base URI empty");
        require(_collector != address(0), "Invalid collector address");
        baseTokenURI = _baseTokenURI;
        mintPriceWei = _mintPriceWei;
        collector = _collector;
        maxSupply = _maxSupply;
        maxPerWallet = _maxPerWallet;
    }

    /// @dev Blocks transfers and approvals-based moves between two non-zero owners; allows mint and burn.
    function _update(address _to, uint256 _tokenId, address _auth) internal override returns (address) {
        address from = _ownerOf(_tokenId);
        if (from != address(0) && _to != address(0)) revert NonTransferable();
        return super._update(_to, _tokenId, _auth);
    }

    function mint() public payable whenNotPaused nonReentrant {
        bool isOwnerMint = (msg.sender == owner());
        if (!isOwnerMint)
            require(msg.value >= mintPriceWei, "Insufficient payment");

        if (maxSupply != 0)
            require(totalMinted < maxSupply, "Sold out");

        if (maxPerWallet != 0)
            require(mintedPerWallet[msg.sender] < maxPerWallet, "Limit reached");

        unchecked { totalMinted++; }

        ++mintedPerWallet[msg.sender];
        _safeMint(msg.sender, totalMinted);

        if (!isOwnerMint) {
            Address.sendValue(collector, mintPriceWei);
            if (msg.value > mintPriceWei)
                Address.sendValue(payable(msg.sender), msg.value - mintPriceWei);
        } else if (msg.value != 0) {
            Address.sendValue(payable(owner()), msg.value);
        }

        //emit Minted(msg.sender, totalMinted, isOwnerMint ? 0 : mintPriceWei);
    }

    function ownerMint(address _to) external onlyOwner {
        if (maxSupply != 0)
            require(totalMinted < maxSupply, "Sold out");

        if (maxPerWallet != 0)
            require(mintedPerWallet[_to] < maxPerWallet, "Limit reached");

        unchecked { totalMinted++; }
        ++mintedPerWallet[_to];
        _safeMint(_to, totalMinted);
        emit OwnerMinted(_to, totalMinted);
    }

    function ownerMintBatch(address[] memory _tos) external onlyOwner {
        if (maxSupply != 0)
            require(totalMinted + _tos.length <= maxSupply, "Sold out");

        for (uint256 i; i < _tos.length; i++) {
            if (maxPerWallet != 0)
              if (mintedPerWallet[_tos[i]] >= maxPerWallet)
                continue;
            unchecked { totalMinted++; }
            ++mintedPerWallet[_tos[i]];
            _safeMint(_tos[i], totalMinted);
            emit OwnerMinted(_tos[i], totalMinted);
        }
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        _requireOwned(_tokenId);
        return baseTokenURI;
    }

    function setBaseTokenURI(string memory _newBaseTokenURI) external onlyOwner {
        require(bytes(_newBaseTokenURI).length > 0, "Empty URI");

        emit BaseTokenUriChanged(baseTokenURI, _newBaseTokenURI);
        baseTokenURI = _newBaseTokenURI;
    }

    function setMintPriceWei(uint256 _newMintPriceWei) external onlyOwner {
        require(_newMintPriceWei != mintPriceWei, "The same price");

        emit PriceChanged(mintPriceWei, _newMintPriceWei);
        mintPriceWei = _newMintPriceWei;
    }

    function setCollector(address payable _newCollector) external onlyOwner {
        require(collector != _newCollector, "Same collector");
        require(_newCollector != address(0), "Invalid address");
        collector = _newCollector;
    }

    function syncCollectorWithOwner() external onlyOwner {
        collector = payable(owner());
    }

    function pause() external onlyOwner {
        _pause();
        emit MintPaused();
    }

    function unpause() external onlyOwner {
        _unpause();
        emit MintUnpaused();
    }

    function withdraw(address payable _to) external nonReentrant onlyOwner {
        require(_to != address(0), "Invalid address");

        uint256 amount = address(this).balance;
        require(amount > 0, "Nothing to withdraw");

        Address.sendValue(_to, amount);
    }

    receive() external payable {}
}
