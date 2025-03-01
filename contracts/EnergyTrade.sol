// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract EnergyTrade is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public energyToken;
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE");
    bytes32 public constant PRODUCER_ROLE = keccak256("PRODUCER_ROLE");
    struct Participant {
        string name;
        bool isRegistered;
    }

    struct EnergyOffer {
        address producer;
        uint256 amount;
        uint256 pricePerUnit;
        bool isActive;
        uint256 escrowedAmount;
        uint8 paymentStage;
    }

    struct Trade {
        uint256 tradeId;
        address buyer;
        address seller;
        uint256 amount;
        uint256 price;
        uint256 timestamp;
    }

    struct Refund {
        uint256 tradeId;
        address buyer;
        uint256 amount;
        string note;
        uint256 timestamp;
    }

    struct Bargain {
        address proposer;
        address acceptor;
        uint256 amount;
        uint256 pricePerUnit;
        bool isAccepted;
    }

    mapping(address => Participant) public participants;
    mapping(uint256 => EnergyOffer) public energyOffers;
    mapping(address => Trade[]) public tradeHistory;
    mapping(uint256 => Refund) public refunds;
    mapping(uint256 => Bargain) public bargains;
    uint256 public offerCounter;
    uint256 public tradeCounter;
    uint256 public bargainCounter;

    uint256 public sellerRewardPercentage = 5; // 5% reward
    address public rewardPoolAddress;

    modifier onlyRegistered() {
        require(participants[msg.sender].isRegistered, "Not registered");
        _;
    }

    event ParticipantRegistered(address indexed participant, string name);
    event EnergyDeposited(
        address indexed producer,
        uint256 amount,
        uint256 pricePerUnit,
        uint256 offerId
    );
    event EnergyPurchased(
        address indexed buyer,
        address indexed producer,
        uint256 amount,
        uint256 price,
        uint256 tradeId
    );
    event EnergyOfferCanceled(uint256 offerId);
    event EnergyWithdrawn(address indexed producer, uint256 amount);
    event EmergencyStopActivated();
    event EmergencyStopDeactivated();
    event PaymentReleased(
        address indexed buyer,
        address indexed producer,
        uint256 amount,
        uint8 stage
    );
    event RefundRequested(
        uint256 tradeId,
        address indexed buyer,
        uint256 amount,
        string note
    );
    event BargainProposed(
        uint256 bargainId,
        address indexed proposer,
        address indexed acceptor,
        uint256 amount,
        uint256 pricePerUnit
    );
    event BargainAccepted(
        uint256 bargainId,
        address indexed proposer,
        address indexed acceptor
    );
    event BargainRejected(
        uint256 bargainId,
        address indexed proposer,
        address indexed acceptor
    );
    event DisputeResolved(
        uint256 tradeId,
        address indexed resolver,
        string resolution
    );
    event SellerRewarded(address indexed seller, uint256 rewardAmount);

    constructor(address tokenAddress) {
        energyToken = IERC20(tokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function initializeTradingPlatform(
        address tokenAddress
    ) external onlyRole(ADMIN_ROLE) {
        energyToken = IERC20(tokenAddress);
    }

    function registerParticipant(
        address participantAddress,
        string memory name
    ) external {
        require(
            !participants[participantAddress].isRegistered,
            "Already registered"
        );
        participants[participantAddress] = Participant(name, true);
        emit ParticipantRegistered(participantAddress, name);
    }

    function depositEnergy(
        uint256 amount,
        uint256 pricePerUnit
    ) external onlyRole(PRODUCER_ROLE) whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        offerCounter++;
        energyOffers[offerCounter] = EnergyOffer(
            msg.sender,
            amount,
            pricePerUnit,
            true,
            0,
            0
        );
        emit EnergyDeposited(msg.sender, amount, pricePerUnit, offerCounter);
    }

    function proposeBargain(
        address acceptor,
        uint256 amount,
        uint256 pricePerUnit
    ) external onlyRegistered whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        bargainCounter++;
        bargains[bargainCounter] = Bargain(
            msg.sender,
            acceptor,
            amount,
            pricePerUnit,
            false
        );
        emit BargainProposed(
            bargainCounter,
            msg.sender,
            acceptor,
            amount,
            pricePerUnit
        );
    }

    function acceptBargain(
        uint256 bargainId
    ) external onlyRegistered whenNotPaused {
        Bargain storage bargain = bargains[bargainId];
        require(bargain.acceptor == msg.sender, "Not the acceptor");
        require(!bargain.isAccepted, "Bargain already accepted");

        bargain.isAccepted = true;
        emit BargainAccepted(bargainId, bargain.proposer, msg.sender);

        // Create a new offer from the bargain
        offerCounter++;
        energyOffers[offerCounter] = EnergyOffer(
            bargain.proposer,
            bargain.amount,
            bargain.pricePerUnit,
            true,
            0,
            0
        );

        // Purchase the energy from the newly created offer
        purchaseEnergy(offerCounter, bargain.amount);
    }

    function rejectBargain(
        uint256 bargainId
    ) external onlyRegistered whenNotPaused {
        Bargain storage bargain = bargains[bargainId];
        require(bargain.acceptor == msg.sender, "Not the acceptor");
        require(!bargain.isAccepted, "Bargain already accepted");

        delete bargains[bargainId];
        emit BargainRejected(bargainId, bargain.proposer, msg.sender);
    }

    function purchaseEnergy(
        uint256 offerId,
        uint256 amount
    ) public onlyRole(CONSUMER_ROLE) whenNotPaused nonReentrant {
        EnergyOffer storage offer = energyOffers[offerId];
        require(offer.isActive, "Offer not active");
        require(offer.amount >= amount, "Insufficient energy available");

        uint256 totalPrice = amount * offer.pricePerUnit;
        require(
            energyToken.transferFrom(msg.sender, address(this), totalPrice),
            "Token transfer failed"
        );

        // Update the offer
        offer.amount -= amount;
        if (offer.amount == 0) {
            offer.isActive = false;
        }

        offer.escrowedAmount += totalPrice;
        offer.paymentStage = 0;

        tradeCounter++;
        tradeHistory[msg.sender].push(
            Trade(
                tradeCounter,
                msg.sender,
                offer.producer,
                amount,
                totalPrice,
                block.timestamp
            )
        );
        tradeHistory[offer.producer].push(
            Trade(
                tradeCounter,
                msg.sender,
                offer.producer,
                amount,
                totalPrice,
                block.timestamp
            )
        );

        emit EnergyPurchased(
            msg.sender,
            offer.producer,
            amount,
            totalPrice,
            tradeCounter
        );
    }

    function releasePayment(
        uint256 offerId
    ) external onlyRole(CONSUMER_ROLE) whenNotPaused nonReentrant {
        EnergyOffer storage offer = energyOffers[offerId];
        require(offer.escrowedAmount > 0, "No escrowed amount");
        require(offer.paymentStage < 4, "All payments already released");

        uint256 paymentAmount = offer.escrowedAmount / 4;
        offer.paymentStage++;
        energyToken.safeTransfer(offer.producer, paymentAmount);

        // Add reward if payment is complete
        if (offer.paymentStage == 4 && rewardPoolAddress != address(0)) {
            uint256 rewardAmount = (offer.escrowedAmount *
                sellerRewardPercentage) / 100;
            energyToken.safeTransferFrom(
                rewardPoolAddress,
                offer.producer,
                rewardAmount
            );
            emit SellerRewarded(offer.producer, rewardAmount);
        }

        emit PaymentReleased(
            msg.sender,
            offer.producer,
            paymentAmount,
            offer.paymentStage
        );
    }

    function requestRefund(
        uint256 tradeId,
        string memory note
    ) external onlyRole(CONSUMER_ROLE) whenNotPaused nonReentrant {
        Trade[] storage trades = tradeHistory[msg.sender];
        bool tradeFound = false;
        uint256 remainingAmount;
        for (uint256 i = 0; i < trades.length; i++) {
            if (trades[i].tradeId == tradeId) {
                tradeFound = true;
                EnergyOffer storage offer = energyOffers[trades[i].tradeId];
                require(offer.escrowedAmount > 0, "No escrowed amount");
                require(
                    offer.paymentStage < 4,
                    "All payments already released"
                );

                remainingAmount =
                    offer.escrowedAmount -
                    (offer.paymentStage * (offer.escrowedAmount / 4));
                offer.escrowedAmount = 0;
                offer.paymentStage = 4; // Mark all payments as released to prevent further releases

                energyToken.safeTransfer(msg.sender, remainingAmount);

                refunds[tradeId] = Refund(
                    tradeId,
                    msg.sender,
                    remainingAmount,
                    note,
                    block.timestamp
                );

                emit RefundRequested(
                    tradeId,
                    msg.sender,
                    remainingAmount,
                    note
                );
                break;
            }
        }
        require(tradeFound, "Trade not found");
    }

    function cancelEnergyOffer(
        uint256 offerId
    ) external onlyRole(PRODUCER_ROLE) whenNotPaused {
        EnergyOffer storage offer = energyOffers[offerId];
        require(offer.producer == msg.sender, "Not the producer");
        require(offer.isActive, "Offer not active");
        offer.isActive = false;
        emit EnergyOfferCanceled(offerId);
    }

    function withdrawEnergy(
        uint256 offerId,
        uint256 amount
    ) external onlyRole(PRODUCER_ROLE) whenNotPaused {
        EnergyOffer storage offer = energyOffers[offerId];
        require(offer.producer == msg.sender, "Not the producer");
        require(offer.isActive, "Offer not active");
        require(offer.amount >= amount, "Not enough energy available");

        offer.amount -= amount;
        if (offer.amount == 0) {
            offer.isActive = false;
        }

        emit EnergyWithdrawn(msg.sender, amount);
    }

    function getEnergyOffers() external view returns (EnergyOffer[] memory) {
        // First count active offers
        uint256 activeOfferCount = 0;
        for (uint256 i = 1; i <= offerCounter; i++) {
            if (energyOffers[i].isActive) {
                activeOfferCount++;
            }
        }

        // Then populate the array with only active offers
        EnergyOffer[] memory offers = new EnergyOffer[](activeOfferCount);
        uint256 counter = 0;
        for (uint256 i = 1; i <= offerCounter; i++) {
            if (energyOffers[i].isActive) {
                offers[counter] = energyOffers[i];
                counter++;
            }
        }
        return offers;
    }

    function disputeTransaction(
        uint256 tradeId,
        string memory resolution
    ) external onlyRole(ADMIN_ROLE) whenNotPaused {
        // Implement dispute resolution mechanism
        emit DisputeResolved(tradeId, msg.sender, resolution);
    }

    function getTradeHistory(
        address participantAddress
    ) external view returns (Trade[] memory) {
        return tradeHistory[participantAddress];
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit EmergencyStopActivated();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
        emit EmergencyStopDeactivated();
    }

    function assignConsumerRole(address user) external onlyRole(ADMIN_ROLE) {
        _grantRole(CONSUMER_ROLE, user);
    }

    function assignProducerRole(address user) external onlyRole(ADMIN_ROLE) {
        _grantRole(PRODUCER_ROLE, user);
    }

    function setSellerRewardPercentage(
        uint256 _percentage
    ) external onlyRole(ADMIN_ROLE) {
        require(_percentage <= 20, "Reward too high"); // Cap at 20%
        sellerRewardPercentage = _percentage;
    }

    function setRewardPoolAddress(
        address _rewardPoolAddress
    ) external onlyRole(ADMIN_ROLE) {
        rewardPoolAddress = _rewardPoolAddress;
    }
}