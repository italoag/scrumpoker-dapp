// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Importações upgradeáveis do OpenZeppelin 5.x
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title ScrumPoker
 * @dev Sistema de Scrum Poker upgradável que opera na moeda nativa da rede (ETH, POL, etc.) e
 * incorpora:
 *
 * 1. Compra de NFTs (badges) com pagamento equivalente a 1 dólar – o valor em wei é calculado
 *    dinamicamente com base em uma cotação que pode ser atualizada pelo owner.
 * 2. Transferência imediata dos fundos para o owner.
 * 3. Gerenciamento de cerimônias (sprints): os usuários solicitam participação em cerimônias,
 *    o Scrum Master aprova a entrada, e as cerimônias são iniciadas com código único e dados do sprint.
 * 4. Votações durante a cerimônia: tanto uma votação geral quanto sessões de votação para funcionalidades,
 *    com emissão de eventos para rastreabilidade.
 * 5. Conclusão da cerimônia, onde os resultados (participação, votos, pontuação e detalhes das votações)
 *    são compilados e incorporados ao NFT dinâmico (badge) do participante.
 * 6. Mecanismo de vesting: as funcionalidades (como votar ou atualizar os metadados do NFT) só ficam
 *    liberadas após um período de vesting.
 * 7. Upgradabilidade usando o padrão UUPS – o contrato é inicializável (sem construtor) e poderá ser
 *    atualizado no futuro sem perda de dados.
 *
 * Notas de segurança:
 * - São utilizados os módulos do OpenZeppelin upgradeable para proteger contra reentrância e manter o
 *   layout de armazenamento consistente.
 * - Cada operação crítica (compra, entrada, votação, conclusão) emite um evento para auditoria.
 */
contract ScrumPoker is 
    Initializable, 
    ERC721Upgradeable, 
    OwnableUpgradeable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    // ****************** Configurações Gerais ******************

    // Valor (em wei) equivalente a 1 dólar – pode ser atualizado pelo owner.
    uint256 public exchangeRate;
    // Timestamp da última atualização da cotação.
    uint256 public lastExchangeRateUpdate;
    // Período de vesting (em segundos); por exemplo, 1 dia = 86400.
    uint256 public vestingPeriod;
    // Contador para geração dos tokenIds (primeiro NFT terá tokenId 1)
    uint256 private nextTokenId;

    // ****************** Mapeamentos de NFT e Vesting ******************

    // Associa cada endereço ao tokenId do NFT adquirido (cada usuário possui um NFT)
    mapping(address => uint256) public userToken;
    // Registra o timestamp de início do vesting para cada usuário
    mapping(address => uint256) public vestingStart;

    // ****************** Estruturas para os Badges (NFTs) ******************

    struct SprintResult {
        uint256 sprintNumber;         // Número do sprint
        uint256 startTime;            // Data/hora de início da cerimônia
        uint256 endTime;              // Data/hora de término da cerimônia
        uint256 totalPoints;          // Pontos acumulados (soma dos votos)
        string[] functionalityCodes;  // Códigos das funcionalidades votadas
        uint256[] functionalityVotes; // Pontuações recebidas em cada funcionalidade
    }

    struct BadgeData {
        string userName;              // Nome do usuário
        address userAddress;          // Endereço do usuário
        uint256 ceremoniesParticipated; // Quantidade de cerimônias em que participou
        uint256 votesCast;            // Número de votos realizados na votação geral
        SprintResult[] sprintResults; // Histórico dos resultados dos sprints
        string externalURI;           // URI para metadados externos (ex.: imagem/avatar)
    }

    // Mapeia o tokenId do NFT para seus metadados dinâmicos.
    mapping(uint256 => BadgeData) private badgeData;

    // Custom getter para BadgeData
    function getBadgeData(uint256 tokenId) external view returns (
        string memory userName,
        address userAddress,
        uint256 ceremoniesParticipated,
        uint256 votesCast,
        SprintResult[] memory sprintResults,
        string memory externalURI
    ) {
        BadgeData storage badge = badgeData[tokenId];
        return (
            badge.userName,
            badge.userAddress,
            badge.ceremoniesParticipated,
            badge.votesCast,
            badge.sprintResults,
            badge.externalURI
        );
    }

    // ****************** Estruturas e Dados das Cerimônias (Sprints) ******************

    struct Ceremony {
        string code;            // Código único da cerimônia
        uint256 sprintNumber;   // Número do sprint associado
        uint256 startTime;      // Data/hora de início
        uint256 endTime;        // Data/hora de término (0 se não concluída)
        address scrumMaster;    // Endereço do Scrum Master (iniciador)
        bool active;            // Indica se a cerimônia está ativa
        address[] participants; // Lista de participantes aprovados
    }

    // Mapeia o código da cerimônia para a estrutura
    mapping(string => Ceremony) private ceremonies;

    // Custom getter para Ceremony
    function getCeremony(string memory code) external view returns (
        string memory _code,
        uint256 sprintNumber,
        uint256 startTime,
        uint256 endTime,
        address scrumMaster,
        bool active,
        address[] memory participants
    ) {
        Ceremony storage ceremony = ceremonies[code];
        return (
            ceremony.code,
            ceremony.sprintNumber,
            ceremony.startTime,
            ceremony.endTime,
            ceremony.scrumMaster,
            ceremony.active,
            ceremony.participants
        );
    }
    // Indica se uma cerimônia existe (código => bool)
    mapping(string => bool) public ceremonyExists;
    // Contador para gerar códigos únicos de cerimônias.
    uint256 public ceremonyCounter;
    // Controle de solicitação de entrada: cerimônia => (usuário => bool)
    mapping(string => mapping(address => bool)) public hasRequestedEntry;
    // Controle de aprovação: cerimônia => (usuário => bool)
    mapping(string => mapping(address => bool)) public ceremonyApproved;
    // Controle de voto geral: cerimônia => (usuário => bool)
    mapping(string => mapping(address => bool)) public ceremonyHasVoted;
    // Armazena o voto geral de cada participante: cerimônia => (usuário => valor)
    mapping(string => mapping(address => uint256)) public ceremonyVotes;

    // ****************** Votações de Funcionalidades (Sessões) ******************

    struct FunctionalityVoteSession {
        string functionalityCode; // Código da funcionalidade votada
        bool active;              // Sessão de votação ativa
        // Controle de votos nesta sessão: participante => bool (se votou)
        mapping(address => bool) hasVoted;
        // Armazena o voto do participante nesta sessão: participante => valor
        mapping(address => uint256) votes;
    }
    // Mapeia cada código de cerimônia para um array de sessões de votação.
    mapping(string => FunctionalityVoteSession[]) private functionalityVoteSessions;

    // ****************** Eventos para Auditoria e Transparência ******************

    event CotacaoOutdated(uint256 lastUpdated);
    event ExchangeRateUpdated(uint256 newRate, uint256 timestamp);
    event NFTPurchased(address indexed buyer, uint256 tokenId, uint256 amountPaid);
    event FundsTransferred(address owner, uint256 amount);
    event CeremonyStarted(string ceremonyCode, uint256 sprintNumber, uint256 startTime, address indexed scrumMaster);
    event CeremonyEntryRequested(string ceremonyCode, address indexed participant);
    event EntryApproved(string ceremonyCode, address indexed participant);
    event VoteCast(string ceremonyCode, address indexed participant, uint256 voteValue);
    event FunctionalityVoteOpened(string ceremonyCode, string functionalityCode, uint256 sessionIndex);
    event FunctionalityVoteCast(string ceremonyCode, uint256 sessionIndex, address indexed participant, uint256 voteValue);
    event CeremonyConcluded(string ceremonyCode, uint256 endTime, uint256 sprintNumber);
    event NFTBadgeMinted(address indexed participant, uint256 tokenId, uint256 sprintNumber);

    // ****************** Inicialização e Upgradabilidade ******************

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(uint256 _initialExchangeRate, uint256 _vestingPeriod) public initializer {
        __ERC721_init("ScrumPokerBadge", "SPB");
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        exchangeRate = _initialExchangeRate;
        lastExchangeRateUpdate = block.timestamp;
        vestingPeriod = _vestingPeriod;
        nextTokenId = 0;
        ceremonyCounter = 1;
    }

    /**
     * @dev Autoriza upgrades; somente o owner pode autorizar.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ****************** Gestão da Cotação ******************

    /**
     * @notice Atualiza a cotação do token nativo para 1 dólar.
     * @param newRate Novo valor (em wei) equivalente a 1 dólar.
     */
    function updateExchangeRate(uint256 newRate) external onlyOwner {
        exchangeRate = newRate;
        lastExchangeRateUpdate = block.timestamp;
        emit ExchangeRateUpdated(newRate, block.timestamp);
    }

    // ****************** Aquisição do NFT (Pagamento) ******************

    /**
     * @notice Permite a compra do NFT (badge) mediante o pagamento de 1 dólar em moeda nativa.
     * @param _userName Nome do usuário.
     * @param _externalURI URI para metadados externos (ex.: imagem/avatar).
     *
     * Se a cotação não foi atualizada há mais de 24 horas, emite o evento `CotacaoOutdated`.
     * Após a verificação, os fundos são transferidos imediatamente para o owner e o NFT é mintado.
     */
    function purchaseNFT(string memory _userName, string memory _externalURI) external payable nonReentrant {
        if (block.timestamp > lastExchangeRateUpdate + 86400) {
            emit CotacaoOutdated(lastExchangeRateUpdate);
        }
        require(msg.value == exchangeRate, "Valor incorreto para 1 dolar");
        require(userToken[msg.sender] == 0, "NFT ja adquirida");

        // Gera o tokenId utilizando pré-incremento (primeiro NFT terá tokenId 1)
        uint256 tokenId = ++nextTokenId;
        _safeMint(msg.sender, tokenId);

        // Inicializa os metadados do badge
        BadgeData storage badge = badgeData[tokenId];
        badge.userName = _userName;
        badge.userAddress = msg.sender;
        badge.ceremoniesParticipated = 0;
        badge.votesCast = 0;
        badge.externalURI = _externalURI;

        userToken[msg.sender] = tokenId;
        vestingStart[msg.sender] = block.timestamp;

        // Cache o valor e o destinatário antes das interações externas
        address payable ownerAddress = payable(owner());
        uint256 amountToSend = msg.value;

        // Emite eventos antes da transferência
        emit NFTPurchased(msg.sender, tokenId, amountToSend);

        // Transfere os fundos para o owner por último (padrão checks-effects-interactions)
        (bool sent, ) = ownerAddress.call{value: amountToSend}("");
        require(sent, "Falha na transferencia dos fundos");
        
        emit FundsTransferred(ownerAddress, amountToSend);
    }

    // ****************** Gerenciamento de Cerimônias (Sprints) ******************

    /**
     * @notice Inicia uma nova cerimônia (sprint), gerando um código único.
     * @param _sprintNumber Número do sprint associado à cerimônia.
     * @return code Código único gerado para a cerimônia.
     */
    function startCeremony(uint256 _sprintNumber) external returns (string memory) {
        string memory code = string(abi.encodePacked("CEREMONY", uint2str(ceremonyCounter)));
        ceremonyCounter++;

        Ceremony storage ceremony = ceremonies[code];
        ceremony.code = code;
        ceremony.sprintNumber = _sprintNumber;
        ceremony.startTime = block.timestamp;
        ceremony.scrumMaster = msg.sender;
        ceremony.active = true;

        ceremonyExists[code] = true;
        emit CeremonyStarted(code, _sprintNumber, ceremony.startTime, msg.sender);
        return code;
    }

    /**
     * @notice Permite que um usuário solicite participação em uma cerimônia.
     * @param _code Código único da cerimônia.
     * Requisito: o usuário deve possuir um NFT.
     */
    function requestCeremonyEntry(string memory _code) external {
        require(ceremonyExists[_code], "Cerimonia inexistente");
        require(userToken[msg.sender] != 0, "Necessario possuir NFT");
        require(!hasRequestedEntry[_code][msg.sender], "Entrada ja solicitada");

        hasRequestedEntry[_code][msg.sender] = true;
        emit CeremonyEntryRequested(_code, msg.sender);
    }

    /**
     * @notice Aprova a entrada de um participante na cerimônia.
     * @param _code Código único da cerimônia.
     * @param _participant Endereço do participante.
     * Apenas o Scrum Master pode aprovar; ao aprovar, o vesting do participante é reiniciado.
     */
    function approveEntry(string memory _code, address _participant) external {
        require(ceremonyExists[_code], "Cerimonia inexistente");
        require(msg.sender == ceremonies[_code].scrumMaster, "Nao autorizado");
        require(hasRequestedEntry[_code][_participant], "Entrada nao solicitada");
        require(!ceremonyApproved[_code][_participant], "Participante ja aprovado");

        ceremonyApproved[_code][_participant] = true;
        ceremonies[_code].participants.push(_participant);
        vestingStart[_participant] = block.timestamp;
        emit EntryApproved(_code, _participant);
    }

    /**
     * @notice Permite que um participante emita seu voto geral na cerimônia.
     * @param _code Código único da cerimônia.
     * @param _voteValue Valor do voto (pontos).
     * Requisitos:
     * - A cerimônia deve estar ativa.
     * - O participante deve estar aprovado.
     * - Não pode ter votado anteriormente.
     * - O NFT deve estar "vested" (após o período de vesting).
     */
    function vote(string memory _code, uint256 _voteValue) external {
        require(ceremonyExists[_code], "Cerimonia inexistente");
        require(ceremonies[_code].active, "Cerimonia nao ativa");
        require(ceremonyApproved[_code][msg.sender], "Participante nao aprovado");
        require(!ceremonyHasVoted[_code][msg.sender], "Ja votou");
        require(block.timestamp >= vestingStart[msg.sender] + vestingPeriod, "NFT ainda nao vested");

        ceremonyVotes[_code][msg.sender] = _voteValue;
        ceremonyHasVoted[_code][msg.sender] = true;
        emit VoteCast(_code, msg.sender, _voteValue);
    }

    // ****************** Votações de Funcionalidades ******************

    /**
     * @notice Abre uma nova sessão de votação para uma funcionalidade específica.
     * @param _code Código único da cerimônia.
     * @param _functionalityCode Código da funcionalidade a ser votada.
     * Requisito: Apenas o Scrum Master pode abrir sessões.
     */
    function openFunctionalityVote(string memory _code, string memory _functionalityCode) external {
        require(ceremonyExists[_code], "Cerimonia inexistente");
        require(msg.sender == ceremonies[_code].scrumMaster, "Nao autorizado");
        require(ceremonies[_code].active, "Cerimonia nao ativa");

        uint256 sessionIndex = functionalityVoteSessions[_code].length;
        FunctionalityVoteSession storage session = functionalityVoteSessions[_code].push();
        session.functionalityCode = _functionalityCode;
        session.active = true;

        emit FunctionalityVoteOpened(_code, _functionalityCode, sessionIndex);
    }

    /**
     * @notice Permite que um participante vote em uma sessão de votação de funcionalidade.
     * @param _code Código único da cerimônia.
     * @param _sessionIndex Índice da sessão.
     * @param _voteValue Valor do voto para a funcionalidade.
     * Requisitos:
     * - A cerimônia deve estar ativa.
     * - O participante deve estar aprovado.
     * - Não pode ter votado nesta sessão.
     * - O NFT deve estar "vested".
     */
    function voteFunctionality(string memory _code, uint256 _sessionIndex, uint256 _voteValue) external {
        require(ceremonyExists[_code], "Cerimonia inexistente");
        require(ceremonies[_code].active, "Cerimonia nao ativa");
        require(ceremonyApproved[_code][msg.sender], "Participante nao aprovado");
        require(_sessionIndex < functionalityVoteSessions[_code].length, "Sessao invalida");

        FunctionalityVoteSession storage session = functionalityVoteSessions[_code][_sessionIndex];
        require(session.active, "Sessao encerrada");
        require(!session.hasVoted[msg.sender], "Ja votou nesta sessao");
        require(block.timestamp >= vestingStart[msg.sender] + vestingPeriod, "NFT ainda nao vested");

        session.votes[msg.sender] = _voteValue;
        session.hasVoted[msg.sender] = true;
        emit FunctionalityVoteCast(_code, _sessionIndex, msg.sender, _voteValue);
    }

    /**
     * @notice Encerra uma sessão de votação de funcionalidade.
     * @param _code Código único da cerimônia.
     * @param _sessionIndex Índice da sessão.
     * Requisito: Apenas o Scrum Master pode encerrar a sessão.
     */
    function closeFunctionalityVote(string memory _code, uint256 _sessionIndex) external {
        require(ceremonyExists[_code], "Cerimonia inexistente");
        require(msg.sender == ceremonies[_code].scrumMaster, "Nao autorizado");
        require(_sessionIndex < functionalityVoteSessions[_code].length, "Sessao invalida");

        FunctionalityVoteSession storage session = functionalityVoteSessions[_code][_sessionIndex];
        require(session.active, "Sessao ja encerrada");

        session.active = false;
        // Opcional: emitir um evento de encerramento, se desejado.
    }

    // ****************** Conclusão da Cerimônia e Atualização do NFT (Badge) ******************

    /**
     * @notice Conclui a cerimônia, compilando os resultados e atualizando os badges (NFTs) dos participantes.
     * Para cada participante aprovado, o contrato:
     * - Calcula a pontuação total (voto geral + votos de funcionalidades);
     * - Reúne os códigos e valores dos votos de cada sessão;
     * - Cria um novo registro de SprintResult e o adiciona ao histórico do NFT.
     *
     * Requisito: Apenas o Scrum Master pode concluir a cerimônia.
     */
    function concludeCeremony(string memory _code) external {
        require(ceremonyExists[_code], "Cerimonia inexistente");
        Ceremony storage ceremony = ceremonies[_code];
        require(ceremony.active, "Cerimonia ja concluida");
        require(msg.sender == ceremony.scrumMaster, "Nao autorizado");

        ceremony.endTime = block.timestamp;
        ceremony.active = false;

        for (uint256 i = 0; i < ceremony.participants.length; i++) {
            address participant = ceremony.participants[i];
            uint256 tokenId = userToken[participant];
            if (tokenId == 0) continue;

            uint256 totalPoints = 0;
            if (ceremonyHasVoted[_code][participant]) {
                totalPoints += ceremonyVotes[_code][participant];
            }

            // Arrays temporários para votos de funcionalidades
            string[] memory funcCodesTemp = new string[](functionalityVoteSessions[_code].length);
            uint256[] memory funcVotesTemp = new uint256[](functionalityVoteSessions[_code].length);
            uint256 count = 0;
            for (uint256 j = 0; j < functionalityVoteSessions[_code].length; j++) {
                FunctionalityVoteSession storage session = functionalityVoteSessions[_code][j];
                if (session.hasVoted[participant]) {
                    funcCodesTemp[count] = session.functionalityCode;
                    funcVotesTemp[count] = session.votes[participant];
                    totalPoints += session.votes[participant];
                    count++;
                }
            }
            // Redimensiona os arrays para o tamanho efetivo
            string[] memory funcCodes = new string[](count);
            uint256[] memory funcVotes = new uint256[](count);
            for (uint256 k = 0; k < count; k++) {
                funcCodes[k] = funcCodesTemp[k];
                funcVotes[k] = funcVotesTemp[k];
            }

            BadgeData storage badge = badgeData[tokenId];
            badge.ceremoniesParticipated += 1;
            if (ceremonyHasVoted[_code][participant]) {
                badge.votesCast += 1;
            }
            SprintResult memory result = SprintResult({
                sprintNumber: ceremony.sprintNumber,
                startTime: ceremony.startTime,
                endTime: ceremony.endTime,
                totalPoints: totalPoints,
                functionalityCodes: funcCodes,
                functionalityVotes: funcVotes
            });
            badge.sprintResults.push(result);
            emit NFTBadgeMinted(participant, tokenId, ceremony.sprintNumber);
        }
        emit CeremonyConcluded(_code, ceremony.endTime, ceremony.sprintNumber);
    }

    // ****************** Função Utilitária: tokenURI ******************

    /**
     * @notice Sobrescreve a função tokenURI para retornar a URI armazenada nos metadados do badge.
     * @param tokenId Identificador do NFT.
     * @return A URI externa definida em BadgeData.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId); // Reverte se o token não existir
        return badgeData[tokenId].externalURI;
        }

    // ****************** Função Utilitária: Conversão de uint256 para string ******************

    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (_i != 0) {
            bstr[--k] = bytes1(uint8(48 + _i % 10));
            _i /= 10;
        }
        return string(bstr);
    }

    // ****************** Funções Receive e Fallback ******************

    receive() external payable {}
    fallback() external payable {}
}
