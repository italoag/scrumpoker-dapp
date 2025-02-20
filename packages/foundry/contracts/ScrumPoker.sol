// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";

contract ScrumPoker is 
    Initializable,
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using SafeMathUpgradeable for uint256;

    CountersUpgradeable.Counter private _tokenIdCounter;
    CountersUpgradeable.Counter private _ceremonyIdCounter;

    struct Ceremony {
        uint256 sprintNumber;
        uint256 startTime;
        uint256 endTime;
        address initiator;
        mapping(address => bool) approvals;
        mapping(string => FeatureVotes) featureVotes;
        string[] features;
        address[] participants;
        bool isConcluded;
    }

    struct FeatureVotes {
        uint256 totalPoints;
        mapping(address => uint256) votes;
        address[] voters;
    }

    struct BadgeMetadata {
        uint256 ceremonyId;
        uint256 sprintNumber;
        uint256 startTime;
        uint256 endTime;
        address user;
        string[] features;
        uint256[] points;
    }

    mapping(uint256 => Ceremony) public ceremonies;
    mapping(uint256 => BadgeMetadata) private _badgeMetadata;
    mapping(address => uint256) private _vestingStart;
    
    uint256 public usdExchangeRate; // Taxa de câmbio em wei (1 USD = x wei da moeda nativa)
    uint256 public constant NFT_PRICE_USD = 1 * 10**18; // 1 USD em wei
    address public scrumMaster;
    uint256 public vestingDuration;
    string private _baseTokenURI;

    event NFTPurchased(address indexed user, uint256 tokenId, uint256 amountPaid);
    event ExchangeRateUpdated(uint256 newRate);
    event CeremonyStarted(uint256 indexed ceremonyId, uint256 sprintNumber);
    event ParticipantApproved(uint256 indexed ceremonyId, address participant);
    event VotingStarted(uint256 indexed ceremonyId, string featureCode);
    event VoteCast(uint256 indexed ceremonyId, address voter, string featureCode, uint256 points);
    event CeremonyConcluded(uint256 indexed ceremonyId);
    event BadgeMinted(address indexed user, uint256 tokenId);
    event VestingStarted(address indexed user, uint256 duration);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address _scrumMaster,
        string memory baseURI,
        uint256 initialExchangeRate
    ) initializer public {
        __ERC721_init("ScrumPokerBadge", "SPB");
        __ERC721URIStorage_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        scrumMaster = _scrumMaster;
        _baseTokenURI = baseURI;
        vestingDuration = 30 days;
        usdExchangeRate = initialExchangeRate;
    }

    // Atualiza a taxa de câmbio (1 USD em wei da moeda nativa)
    function setExchangeRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "Taxa invalida");
        usdExchangeRate = newRate;
        emit ExchangeRateUpdated(newRate);
    }

    // Calcula o preço do NFT na moeda nativa
    function calculateNFTPrice() public view returns (uint256) {
        return NFT_PRICE_USD.div(usdExchangeRate);
    }

    // Compra de NFT com moeda nativa
    function buyNFT() external payable {
        uint256 requiredAmount = calculateNFTPrice();
        require(msg.value >= requiredAmount, "Valor insuficiente");
        
        // Envia o valor excedente de volta para o usuário
        if (msg.value > requiredAmount) {
            payable(msg.sender).transfer(msg.value - requiredAmount);
        }
        
        // Transfere o valor para o owner
        payable(owner()).transfer(requiredAmount);
        
        _tokenIdCounter.increment();
        uint256 tokenId = _tokenIdCounter.current();
        _safeMint(msg.sender, tokenId);
        
        _vestingStart[msg.sender] = block.timestamp;
        
        emit NFTPurchased(msg.sender, tokenId, requiredAmount);
        emit VestingStarted(msg.sender, vestingDuration);
    }

    // Verifica se o usuário está habilitado para votar
    modifier onlyVested() {
        require(block.timestamp >= _vestingStart[msg.sender].add(vestingDuration), 
            "Direitos nao liberados");
        _;
    }

    // Restante do contrato mantido com as modificações necessárias...
    // [As outras funções permanecem semelhantes com ajustes para usar o novo sistema de vesting]

    function vote(uint256 ceremonyId, string memory featureCode, uint256 points) external onlyVested {
        Ceremony storage ceremony = ceremonies[ceremonyId];
        require(ceremony.approvals[msg.sender], "Participante nao aprovado");
        require(!ceremony.isConcluded, "Cerimonia concluida");
        
        FeatureVotes storage votes = ceremony.featureVotes[featureCode];
        require(votes.votes[msg.sender] == 0, "Voto ja registrado");
        
        votes.totalPoints += points;
        votes.votes[msg.sender] = points;
        votes.voters.push(msg.sender);
        
        emit VoteCast(ceremonyId, msg.sender, featureCode, points);
    }

    // Funções administrativas e auxiliares...
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    // Função para sacar fundos eventualmente presos (emergência)
    function withdrawStuckFunds() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}