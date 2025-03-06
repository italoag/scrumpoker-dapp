// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract ScPoker is
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // Estrutura de dados otimizada
    struct Ceremony {
        uint40 startTime;
        uint40 endTime;
        uint16 sprintNumber;
        address initiator;
        mapping(address => bool) approvals;
        mapping(bytes32 => uint256) featureVotes;
        bytes32[] features;
        address[] participants;
    }

    // Estado do contrato
    uint256 private _nextTokenId;
    uint256 private _nextCeremonyId;
    string private _baseTokenURI;
    uint256 private _usdExchangeRate;
    
    mapping(uint256 => Ceremony) private _ceremonies;
    mapping(address => uint256) private _vestedUntil;

    // Eventos
    event NFTPurchased(address indexed buyer, uint256 tokenId);
    event CeremonyStarted(uint256 indexed ceremonyId, uint16 sprintNumber);
    event ParticipantApproved(uint256 indexed ceremonyId, address participant);
    event VotingStarted(uint256 indexed ceremonyId, bytes32 featureHash);
    event VoteCasted(uint256 indexed ceremonyId, address voter, bytes32 featureHash, uint8 points);
    event CeremonyConcluded(uint256 indexed ceremonyId, uint256[] tokenIds);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        string memory baseURI,
        uint256 initialExchangeRate
    ) public initializer {
        __ERC721_init("ScrumPokerBadge", "SPB");
        __ERC721Enumerable_init();
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _transferOwnership(initialOwner);
        _baseTokenURI = baseURI;
        _usdExchangeRate = initialExchangeRate;
        _nextTokenId = 1;
        _nextCeremonyId = 1;
    }

    function uint2str(uint256 value) internal pure returns (string memory) {
        return string(abi.encodePacked(value));
    }

    function addressToString(address addr) internal pure returns (string memory) {
        return string(abi.encodePacked(addr));
    }

    function toHexString(uint256 value) internal pure returns (string memory) {
        return string(abi.encodePacked(value));
    }

    // Função para atualizar a taxa de câmbio
    function updateExchangeRate(uint256 newRate) external onlyOwner {
        _usdExchangeRate = newRate;
    }

    // Calcula o preço do NFT em moeda nativa
    function calculateNFTPrice() public view returns (uint256) {
        return (1 ether * 1e18) / _usdExchangeRate; // 1 USD em wei
    }

    // Compra de NFT com verificação de valor
    function purchaseNFT() external payable nonReentrant {
        uint256 price = calculateNFTPrice();
        require(msg.value >= price, "Insufficient payment");
        
        // Reembolso do excesso
        if (msg.value > price) {
            payable(msg.sender).transfer(msg.value - price);
        }

        uint256 tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);
        _vestedUntil[msg.sender] = block.timestamp + 30 days;
        
        // Transferência do valor para o owner
        payable(owner()).transfer(price);
        
        emit NFTPurchased(msg.sender, tokenId);
    }

    // Gestão de cerimônias
    function startCeremony(uint16 sprintNumber) external onlyOwner {
        uint256 ceremonyId = _nextCeremonyId++;
        
        Ceremony storage ceremony = _ceremonies[ceremonyId];
        ceremony.sprintNumber = sprintNumber;
        ceremony.startTime = uint40(block.timestamp);
        ceremony.initiator = msg.sender;
        
        emit CeremonyStarted(ceremonyId, sprintNumber);
    }

    // Aprovação de participantes
    function approveParticipant(uint256 ceremonyId, address participant) external {
        require(_msgSender() == owner() || _msgSender() == _ceremonies[ceremonyId].initiator, "Not authorized");
        _ceremonies[ceremonyId].approvals[participant] = true;
        _ceremonies[ceremonyId].participants.push(participant);
        emit ParticipantApproved(ceremonyId, participant);
    }

    // Sistema de votação
    function castVote(
        uint256 ceremonyId,
        bytes32 featureHash,
        uint8 points
    ) external {
        require(_vestedUntil[msg.sender] <= block.timestamp, "Vesting period active");
        require(points > 0 && points <= 21, "Invalid points");
        
        Ceremony storage ceremony = _ceremonies[ceremonyId];
        require(ceremony.approvals[msg.sender], "Not approved");
        
        ceremony.featureVotes[featureHash] += points;
        emit VoteCasted(ceremonyId, msg.sender, featureHash, points);
    }

    // Conclusão da cerimônia
    function concludeCeremony(uint256 ceremonyId) external onlyOwner {
        Ceremony storage ceremony = _ceremonies[ceremonyId];
        require(ceremony.endTime == 0, "Already concluded");
        
        ceremony.endTime = uint40(block.timestamp);
        uint256[] memory tokenIds = new uint256[](ceremony.participants.length);

        for (uint256 i = 0; i < ceremony.participants.length; i++) {
            uint256 tokenId = _nextTokenId++;
            _safeMint(ceremony.participants[i], tokenId);
            tokenIds[i] = tokenId;
        }

        emit CeremonyConcluded(ceremonyId, tokenIds);
    }

    // Funções obrigatórias
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        virtual
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }


}

