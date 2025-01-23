// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract EnergyTrade is  ReentrancyGuard {
    IERC20 public energyToken;
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    struct Participant {
        string name;
        bool isRegistered;
    }

    struct EnergyOffer {
        address producer;
        uint256 amount;
        uint256 pricePerUnit;
        bool isActive;
    }

    struct Trade {
        address buyer;
        address seller;
        uint256 amount;
        uint256 price;
        uint256 timestamp;
    }

    mapping(address => Participant) public participants;
    mapping(uint256 => EnergyOffer) public energyOffers;
    mapping(address => Trade[]) public tradeHistory;
    uint256 public offerCounter;
    bool public stopped = false;

    modifier onlyRegistered() {
        require(participants[msg.sender].isRegistered, "Not registered");
        _;
    }

    modifier stopInEmergency() {
        require(!stopped, "Emergency stop activated");
        _;
    }

    event ParticipantRegistered(address indexed participant, string name);
    event EnergyDeposited(address indexed producer, uint256 amount, uint256 pricePerUnit, uint256 offerId);
    event EnergyPurchased(address indexed buyer, address indexed producer, uint256 amount, uint256 price);
    event EnergyOfferCanceled(uint256 offerId);
    event EnergyWithdrawn(address indexed producer, uint256 amount);
    event EmergencyStopActivated();
    event EmergencyStopDeactivated();

    constructor(address tokenAddress) {
        energyToken = IERC20(tokenAddress);
    }

    function initializeTradingPlatform(address tokenAddress) external {
        energyToken = IERC20(tokenAddress);
    }

    function registerParticipant(address participantAddress, string memory name) external {
        require(!participants[participantAddress].isRegistered, "Already registered");
        participants[participantAddress] = Participant(name, true);
        emit ParticipantRegistered(participantAddress, name);
    }

    function depositEnergy(uint256 amount, uint256 pricePerUnit) external onlyRegistered stopInEmergency {
        require(amount > 0, "Amount must be greater than zero");
        offerCounter++;
        energyOffers[offerCounter] = EnergyOffer(msg.sender, amount, pricePerUnit, true);
        emit EnergyDeposited(msg.sender, amount, pricePerUnit, offerCounter);
    }

    function purchaseEnergy(uint256 offerId, uint256 amount) external onlyRegistered stopInEmergency nonReentrant {
        EnergyOffer storage offer = energyOffers[offerId];
        require(offer.isActive, "Offer not active");
        require(offer.amount >= amount, "Not enough energy available");
        uint256 totalPrice = amount * offer.pricePerUnit;
        require(energyToken.transferFrom(msg.sender, offer.producer, totalPrice), "Token transfer failed");

        offer.amount -= amount;
        if (offer.amount == 0) {
            offer.isActive = false;
        }

        tradeHistory[msg.sender].push(Trade(msg.sender, offer.producer, amount, totalPrice, block.timestamp));
        tradeHistory[offer.producer].push(Trade(msg.sender, offer.producer, amount, totalPrice, block.timestamp));

        emit EnergyPurchased(msg.sender, offer.producer, amount, totalPrice);
    }

    function cancelEnergyOffer(uint256 offerId) external onlyRegistered stopInEmergency {
        EnergyOffer storage offer = energyOffers[offerId];
        require(offer.producer == msg.sender, "Not the producer");
        require(offer.isActive, "Offer not active");
        offer.isActive = false;
        emit EnergyOfferCanceled(offerId);
    }

    function withdrawEnergy(uint256 offerId, uint256 amount) external onlyRegistered stopInEmergency {
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
        EnergyOffer[] memory offers = new EnergyOffer[](offerCounter);
        uint256 counter = 0;
        for (uint256 i = 1; i <= offerCounter; i++) {
            if (energyOffers[i].isActive) {
                offers[counter] = energyOffers[i];
                counter++;
            }
        }
        return offers;
    }

    function disputeTransaction(address buyerAddress, address sellerAddress, uint256 transactionId) external onlyRegistered stopInEmergency {
        // Implement dispute resolution mechanism
    }

    function getTradeHistory(address participantAddress) external view returns (Trade[] memory) {
        return tradeHistory[participantAddress];
    }

    function emergencyStop() external  {
        stopped = true;
        emit EmergencyStopActivated();
    }

    function deactivateEmergencyStop() external  {
        stopped = false;
        emit EmergencyStopDeactivated();
    }
}