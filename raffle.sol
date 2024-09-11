// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LimitReceiver is VRFConsumerBaseV2Plus, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint public exactAmount;
    uint public totalLimit;
    uint public totalDeposited;
    uint public withdrawalCooldown = 1 days;
    uint public lastWithdrawalTime;
    uint public unlockDate;
    bool public randomGenerated;  // Controla se o número aleatório já foi gerado

    VRFV2PlusClient.RandomWordsRequest public vrfRequest;
    uint256 public subscriptionId;
    uint256 public randomResult;
    uint256 public maxRange;

    bytes32 public keyHash;
    uint32 public callbackGasLimit = 500000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;

    IVRFCoordinatorV2Plus COORDINATOR;

    mapping(address => uint) public deposits;
    address[] public depositors;
    mapping(address => bool) public hasDeposited;

    event Deposit(address indexed from, uint amount);
    event Refund(address indexed to, uint amount);
    event Withdrawal(address indexed to, uint amount, string tokenType);
    event RandomNumberRequested(uint256 requestId);
    event RandomNumberGenerated(uint256 randomNumber);

    modifier afterUnlockDate() {
        require(block.timestamp >= unlockDate, "acao nao permitida antes da data de desbloqueio");
        _;
    }

    // Construtor do contrato
    constructor(
        uint _exactAmount,
        uint _totalLimit,
        uint _unlockDate,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint256 _subscriptionId
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        COORDINATOR = IVRFCoordinatorV2Plus(_vrfCoordinator); // Inicializa o coordenador VRF
        exactAmount = _exactAmount;
        totalLimit = _totalLimit;
        unlockDate = _unlockDate;
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        randomGenerated = false;  // Inicializa como falso para permitir a geração
    }

    function requestRandomNumber(uint _maxRange) external onlyOwner {
        require(!randomGenerated, "Random number already generated");
        require(_maxRange > 0, "Max range must be greater than 0");
        maxRange = _maxRange;

        // Passar um objeto com todos os parâmetros
        VRFV2PlusClient.RandomWordsRequest memory request = VRFV2PlusClient.RandomWordsRequest({
            keyHash: keyHash,
            subId: subscriptionId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit: callbackGasLimit,
            numWords: numWords,
            extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({
                nativePayment: false  // Altere para true se for pagar com ETH
            }))
        });

        uint256 requestId = COORDINATOR.requestRandomWords(request);  // Chamada com o objeto
        randomGenerated = true;  // Bloqueia futuras chamadas
        emit RandomNumberRequested(requestId);
    }

    function fulfillRandomWords(uint256, uint256[] calldata randomWords) internal override {
        randomResult = randomWords[0] % maxRange + 1;
        emit RandomNumberGenerated(randomResult);
    }

    receive() external payable {
        require(msg.value > 0, "O valor deve ser maior que zero");

        if (hasDeposited[msg.sender]) {
            (bool success, ) = msg.sender.call{value: msg.value}("");
            require(success, "Reembolso falhou");
            emit Refund(msg.sender, msg.value);
            return;
        }

        if (msg.value != exactAmount) {
            (bool success, ) = msg.sender.call{value: msg.value}("");
            require(success, "Reembolso falhou");
            emit Refund(msg.sender, msg.value);
            return;
        }

        require(totalDeposited + msg.value <= totalLimit, "Limite total de deposito atingido");

        _registerDeposit(msg.sender, msg.value);
    }

    fallback() external payable {
        revert("Apenas ETH e aceito");
    }

    function _registerDeposit(address depositor, uint amount) internal {
        if (deposits[depositor] == 0) {
            depositors.push(depositor);
        }
        hasDeposited[depositor] = true;
        deposits[depositor] += amount;
        totalDeposited += amount;
        emit Deposit(depositor, amount);
    }

    function withdraw(address payable _to, uint _amount) external onlyOwner nonReentrant afterUnlockDate {
        require(_amount <= address(this).balance, "Saldo insuficiente");
        lastWithdrawalTime = block.timestamp;
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "Falha na retirada");
        emit Withdrawal(_to, _amount, "Ether");
    }
}