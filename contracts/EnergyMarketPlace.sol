// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./EnergyToken.sol";
import "./EnergyEscrow.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title EnergyMarketplace
 * @dev Main contract for the peer-to-peer energy trading platform with hash-based IDs
 */
contract EnergyMarketplace is
    ReentrancyGuard,
    Pausable,
    AccessControl,
    Ownable
{
    // Define roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    // Add a dispute period
    uint256 public constant DISPUTE_PERIOD = 24 hours;

    // Reference to the energy token
    EnergyToken public energyToken;

    // Reference to the escrow contract
    EnergyEscrow public escrowContract;

    // Enum for offer type
    enum OfferType {
        BUY,
        SELL
    }

    // Enum for offer status
    enum OfferStatus {
        ACTIVE,
        NEGOTIATING,
        AGREED,
        IN_PROGRESS,
        COMPLETED,
        CANCELLED
    }

    // Add a new field to track when each milestone was reported
    struct MilestoneCompletion {
        uint256 timestamp;
        bool canDispute;
        bool disputed;
    }
    // Struct to represent an energy trading offer
    struct Offer {
        bytes32 id;
        address creator;
        OfferType offerType;
        uint256 energyAmount; // in kWh
        uint256 pricePerUnit; // price in tokens per kWh
        uint256 totalPrice;
        uint256 startTime;
        uint256 endTime;
        OfferStatus status;
        address counterparty; // Address of the trading partner once agreed
        uint256 createdAt;
    }

    // Struct to represent a negotiation message
    struct NegotiationMessage {
        address sender;
        uint256 timestamp;
        string message;
        uint256 proposedPrice; // 0 if not proposing a new price
        uint256 proposedEnergyAmount; // 0 if not proposing a new amount
    }

    // Struct to represent a trade agreement
    struct Agreement {
        bytes32 id;
        bytes32 offerId;
        address buyer;
        address seller;
        uint256 finalEnergyAmount;
        uint256 finalTotalPrice;
        uint256 agreedAt;
        bytes32 escrowId;
        bool isActive;
        mapping(uint256 => MilestoneCompletion) milestones;
    }

    // Counter for nonce (used to ensure unique IDs)
    uint256 private nonce = 0;

    // Mapping from offer ID to Offer
    mapping(bytes32 => Offer) public offers;

    // Mapping from offer ID to array of negotiation messages
    mapping(bytes32 => NegotiationMessage[]) public negotiations;

    // Mapping from agreement ID to Agreement
    mapping(bytes32 => Agreement) public agreements;

    // Mapping of user address to their created offers
    mapping(address => bytes32[]) public userOffers;

    // Mapping of user address to their agreements
    mapping(address => bytes32[]) public userAgreements;

    // Set of all active offer IDs
    bytes32[] public activeOfferIds;
    mapping(bytes32 => uint256) private activeOfferIndexes;

    // Events
    event OfferCreated(
        bytes32 indexed offerId,
        address indexed creator,
        OfferType offerType
    );
    event OfferUpdated(bytes32 indexed offerId, OfferStatus status);
    event NegotiationMessageAdded(bytes32 indexed offerId, address sender);
    event AgreementCreated(
        bytes32 indexed agreementId,
        bytes32 indexed offerId,
        address buyer,
        address seller
    );
    event EnergyDeliveryProgress(
        bytes32 indexed agreementId,
        uint256 percentage
    );
    event TradeCompleted(bytes32 indexed agreementId);
    event TradeRefunded(bytes32 indexed agreementId, string reason);
    event MilestoneDisputed(
        bytes32 indexed agreementId,
        uint256 percentage,
        string reason
    );

    /**
     * @dev Constructor to set the energy token address
     * @param _tokenAddress Address of the energy token contract
     */
    constructor(address _tokenAddress) Ownable(msg.sender) {
        energyToken = EnergyToken(_tokenAddress);
        escrowContract = new EnergyEscrow(address(energyToken));

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Generate a unique hash-based ID
     * @param _creator Address of the creator
     * @param _salt Additional salt value
     * @return bytes32 hash that serves as ID
     */
    function generateUniqueId(
        address _creator,
        uint256 _salt
    ) internal returns (bytes32) {
        nonce++;
        return
            keccak256(
                abi.encodePacked(
                    _creator,
                    block.timestamp,
                    _salt,
                    nonce,
                    blockhash(block.number - 1)
                )
            );
    }

    /**
     * @dev Create a new energy trading offer
     * @param _offerType Type of the offer (BUY or SELL)
     * @param _energyAmount Amount of energy in kWh
     * @param _pricePerUnit Price per kWh in tokens
     * @param _startTime Start time for energy delivery
     * @param _endTime End time for energy delivery
     * @return offerId Hash ID of the created offer
     */
    function createOffer(
        OfferType _offerType,
        uint256 _energyAmount,
        uint256 _pricePerUnit,
        uint256 _startTime,
        uint256 _endTime
    ) external whenNotPaused nonReentrant returns (bytes32 offerId) {
        require(_energyAmount > 0, "Energy amount must be greater than zero");
        require(_pricePerUnit > 0, "Price per unit must be greater than zero");
        require(_endTime > _startTime, "End time must be after start time");
        require(
            _startTime > block.timestamp,
            "Start time must be in the future"
        );

        uint256 totalPrice = _energyAmount * _pricePerUnit;

        // Generate a unique hash-based ID
        offerId = generateUniqueId(msg.sender, uint256(uint160(_offerType)));

        offers[offerId] = Offer({
            id: offerId,
            creator: msg.sender,
            offerType: _offerType,
            energyAmount: _energyAmount,
            pricePerUnit: _pricePerUnit,
            totalPrice: totalPrice,
            startTime: _startTime,
            endTime: _endTime,
            status: OfferStatus.ACTIVE,
            counterparty: address(0),
            createdAt: block.timestamp
        });

        userOffers[msg.sender].push(offerId);

        // Add to active offers
        activeOfferIds.push(offerId);
        activeOfferIndexes[offerId] = activeOfferIds.length - 1;

        emit OfferCreated(offerId, msg.sender, _offerType);

        return offerId;
    }

    function updateOffer(
        bytes32 _offerId,
        uint256 _energyAmount,
        uint256 _pricePerUnit,
        uint256 _startTime,
        uint256 _endTime
    ) external whenNotPaused nonReentrant {
        Offer storage offer = offers[_offerId];
        require(offer.id == _offerId, "Offer does not exist");
        require(msg.sender == offer.creator, "Only creator can update offer");
        require(
            offer.status == OfferStatus.ACTIVE ||
                offer.status == OfferStatus.NEGOTIATING,
            "Offer cannot be updated"
        );

        // Validate inputs
        require(_energyAmount > 0, "Energy amount must be greater than zero");
        require(_pricePerUnit > 0, "Price per unit must be greater than zero");
        require(_endTime > _startTime, "End time must be after start time");
        require(
            _startTime > block.timestamp,
            "Start time must be in the future"
        );

        // Update the offer
        offer.energyAmount = _energyAmount;
        offer.pricePerUnit = _pricePerUnit;
        offer.totalPrice = _energyAmount * _pricePerUnit;
        offer.startTime = _startTime;
        offer.endTime = _endTime;

        emit OfferUpdated(_offerId, offer.status);
    }

    /**
     * @dev Add a negotiation message to an offer
     * @param _offerId ID of the offer
     * @param _message Text message for negotiation
     * @param _proposedPrice New proposed price (0 if not proposing a new price)
     * @param _proposedEnergyAmount New proposed energy amount (0 if not proposing a new amount)
     */
    function addNegotiationMessage(
        bytes32 _offerId,
        string calldata _message,
        uint256 _proposedPrice,
        uint256 _proposedEnergyAmount
    ) external whenNotPaused nonReentrant {
        Offer storage offer = offers[_offerId];
        require(offer.id == _offerId, "Offer does not exist");
        require(
            offer.status == OfferStatus.ACTIVE ||
                offer.status == OfferStatus.NEGOTIATING,
            "Offer is not open for negotiation"
        );

        // Update offer status if this is the first negotiation
        if (offer.status == OfferStatus.ACTIVE) {
            offer.status = OfferStatus.NEGOTIATING;
            emit OfferUpdated(_offerId, OfferStatus.NEGOTIATING);
        }

        negotiations[_offerId].push(
            NegotiationMessage({
                sender: msg.sender,
                timestamp: block.timestamp,
                message: _message,
                proposedPrice: _proposedPrice,
                proposedEnergyAmount: _proposedEnergyAmount
            })
        );

        emit NegotiationMessageAdded(_offerId, msg.sender);
    }

    /**
     * @dev Create a trade agreement from an offer
     * @param _offerId ID of the offer
     * @param _finalPrice Final agreed total price
     * @return agreementId ID of the created agreement
     */
    function createAgreement(
        bytes32 _offerId,
        uint256 _finalPrice,
        uint256 _finalEnergyAmount
    ) external whenNotPaused nonReentrant returns (bytes32) {
        Offer storage offer = offers[_offerId];
        require(offer.id == _offerId, "Offer does not exist");
        require(
            offer.status == OfferStatus.ACTIVE ||
                offer.status == OfferStatus.NEGOTIATING,
            "Offer is not available for agreement"
        );

        // Validate the final energy amount
        require(
            _finalEnergyAmount > 0,
            "Energy amount must be greater than zero"
        );

        address buyer;
        address seller;

        if (offer.offerType == OfferType.BUY) {
            buyer = offer.creator;
            seller = msg.sender;
            require(msg.sender != buyer, "Cannot agree to your own offer");
        } else {
            // OfferType.SELL
            seller = offer.creator;
            buyer = msg.sender;
            require(msg.sender != seller, "Cannot agree to your own offer");
        }

        // Generate unique agreement ID
        bytes32 agreementId = generateUniqueId(
            msg.sender,
            uint256(_finalPrice)
        );

        // Update the offer
        offer.status = OfferStatus.AGREED;
        offer.counterparty = msg.sender;

        // Remove from active offers
        _removeFromActiveOffers(_offerId);

        // Create an escrow for the trade
        bytes32 escrowId = escrowContract.createEscrow(
            buyer,
            seller,
            _finalEnergyAmount,
            _finalPrice
        );

        // Create the agreement
        Agreement storage newAgreement = agreements[agreementId];
        newAgreement.id = agreementId;
        newAgreement.offerId = _offerId;
        newAgreement.buyer = buyer;
        newAgreement.seller = seller;
        newAgreement.finalEnergyAmount = _finalEnergyAmount;
        newAgreement.finalTotalPrice = _finalPrice;
        newAgreement.agreedAt = block.timestamp;
        newAgreement.escrowId = escrowId;
        newAgreement.isActive = true;

        // Update user agreements
        userAgreements[buyer].push(agreementId);
        userAgreements[seller].push(agreementId);

        emit AgreementCreated(agreementId, _offerId, buyer, seller);
        emit OfferUpdated(_offerId, OfferStatus.AGREED);

        return agreementId;
    }

    /**
     * @dev Remove an offer from the active offers list
     * @param _offerId ID of the offer to remove
     */
    function _removeFromActiveOffers(bytes32 _offerId) internal {
        uint256 index = activeOfferIndexes[_offerId];
        uint256 lastIndex = activeOfferIds.length - 1;

        if (index != lastIndex) {
            bytes32 lastOfferId = activeOfferIds[lastIndex];
            activeOfferIds[index] = lastOfferId;
            activeOfferIndexes[lastOfferId] = index;
        }

        activeOfferIds.pop();
        delete activeOfferIndexes[_offerId];
    }

    /**
     * @dev Start the energy transfer process
     * @param _agreementId ID of the agreement
     */
    function startEnergyTransfer(
        bytes32 _agreementId
    ) external whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement is not active");

        Offer storage offer = offers[agreement.offerId];
        require(
            msg.sender == agreement.buyer,
            "Only buyer can start the energy transfer"
        );

        // Transfer tokens to escrow
        require(
            energyToken.transferFrom(
                agreement.buyer,
                address(escrowContract),
                agreement.finalTotalPrice
            ),
            "Token transfer to escrow failed"
        );

        // Update offer status
        offer.status = OfferStatus.IN_PROGRESS;
        emit OfferUpdated(agreement.offerId, OfferStatus.IN_PROGRESS);

        // Start escrow
        escrowContract.startEscrow(agreement.escrowId);
    }

    /**
     * @dev Report energy delivery progress
     * @param _agreementId ID of the agreement
     * @param _percentage Percentage of energy delivered (25, 50, 75, or 100)
     */
    function reportEnergyDelivery(
        bytes32 _agreementId,
        uint256 _percentage
    ) external whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement is not active");
        require(
            msg.sender == agreement.seller,
            "Only seller can report energy delivery"
        );
        require(
            _percentage == 25 ||
                _percentage == 50 ||
                _percentage == 75 ||
                _percentage == 100,
            "Percentage must be 25, 50, 75, or 100"
        );

        // Release appropriate amount from escrow
        escrowContract.releasePayment(agreement.escrowId, _percentage);

        // Report milestone completion with dispute period
        agreement.milestones[_percentage] = MilestoneCompletion({
            timestamp: block.timestamp,
            canDispute: true,
            disputed: false
        });

        emit EnergyDeliveryProgress(_agreementId, _percentage);

        // If 100% delivered, complete the trade
        if (_percentage == 100) {
            completeAgreement(_agreementId);
        }
    }

    /**
     * @dev Complete an agreement after full delivery
     * @param _agreementId ID of the agreement
     */
    function completeAgreement(bytes32 _agreementId) internal {
        Agreement storage agreement = agreements[_agreementId];
        Offer storage offer = offers[agreement.offerId];

        agreement.isActive = false;
        offer.status = OfferStatus.COMPLETED;

        emit TradeCompleted(_agreementId);
        emit OfferUpdated(agreement.offerId, OfferStatus.COMPLETED);
    }

    /**
     * @dev Dispute and request refund for incomplete delivery
     * @param _agreementId ID of the agreement
     * @param _reason Reason for the refund request
     */
    function disputeAndRefund(
        bytes32 _agreementId,
        string calldata _reason
    ) external whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement is not active");
        require(msg.sender == agreement.buyer, "Only buyer can dispute");

        Offer storage offer = offers[agreement.offerId];

        // Process refund through escrow
        escrowContract.processRefund(agreement.escrowId);

        agreement.isActive = false;
        offer.status = OfferStatus.CANCELLED;

        emit TradeRefunded(_agreementId, _reason);
        emit OfferUpdated(agreement.offerId, OfferStatus.CANCELLED);
    }

    /**
     * @dev Get all active offers
     * @return Array of active offer IDs
     */
    function getActiveOffers() external view returns (bytes32[] memory) {
        return activeOfferIds;
    }

    /**
     * @dev Get negotiation messages for an offer
     * @param _offerId ID of the offer
     * @return Array of negotiation messages
     */
    function getNegotiationMessages(
        bytes32 _offerId
    ) external view returns (NegotiationMessage[] memory) {
        return negotiations[_offerId];
    }

    /**
     * @dev Get offers created by a user
     * @param _user Address of the user
     * @return Array of offer IDs created by the user
     */
    function getUserOffers(
        address _user
    ) external view returns (bytes32[] memory) {
        return userOffers[_user];
    }

    /**
     * @dev Get agreements associated with a user
     * @param _user Address of the user
     * @return Array of agreement IDs associated with the user
     */
    function getUserAgreements(
        address _user
    ) external view returns (bytes32[] memory) {
        return userAgreements[_user];
    }

    // ============= Admin functions =============

    /**
     * @dev Pause the contract
     * Only callable by admin
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     * Only callable by admin
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Set a new escrow contract
     * @param _newEscrowContract Address of the new escrow contract
     * Only callable by owner
     */
    function setEscrowContract(address _newEscrowContract) external onlyOwner {
        require(
            _newEscrowContract != address(0),
            "Invalid escrow contract address"
        );
        escrowContract = EnergyEscrow(_newEscrowContract);
    }

    /**
     * @dev Grant moderator role to an address
     * @param _account Address to grant the role to
     */
    function addModerator(address _account) external onlyRole(ADMIN_ROLE) {
        grantRole(MODERATOR_ROLE, _account);
    }

    /**
     * @dev Grant admin role to an address
     * @param _account Address to grant the role to
     */
    function addAdmin(address _account) external onlyRole(ADMIN_ROLE) {
        grantRole(ADMIN_ROLE, _account);
    }

    /**
     * @dev Revoke moderator role from an address
     * @param _account Address to revoke the role from
     */
    function removeModerator(address _account) external onlyRole(ADMIN_ROLE) {
        revokeRole(MODERATOR_ROLE, _account);
    }

    /**
     * @dev Cancel an offer (for moderation purposes)
     * @param _offerId ID of the offer to cancel
     * Only callable by moderators or admins
     */
    function moderateOffer(bytes32 _offerId) external onlyRole(MODERATOR_ROLE) {
        Offer storage offer = offers[_offerId];
        require(offer.id == _offerId, "Offer does not exist");
        require(
            offer.status == OfferStatus.ACTIVE ||
                offer.status == OfferStatus.NEGOTIATING,
            "Offer cannot be moderated"
        );

        offer.status = OfferStatus.CANCELLED;

        // Remove from active offers if needed
        if (
            activeOfferIndexes[_offerId] > 0 ||
            (activeOfferIds.length > 0 && activeOfferIds[0] == _offerId)
        ) {
            _removeFromActiveOffers(_offerId);
        }

        emit OfferUpdated(_offerId, OfferStatus.CANCELLED);
    }

    // Add a function to finalize a milestone after dispute period
    function finalizeMilestone(
        bytes32 _agreementId,
        uint256 _percentage
    ) external whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement is not active");

        MilestoneCompletion storage milestone = agreement.milestones[
            _percentage
        ];
        require(milestone.timestamp > 0, "Milestone not reported yet");
        require(milestone.canDispute, "Milestone already finalized");
        require(!milestone.disputed, "Milestone is disputed");
        require(
            block.timestamp > milestone.timestamp + DISPUTE_PERIOD,
            "Dispute period not over"
        );

        // Mark as no longer disputable
        milestone.canDispute = false;

        // Release payment
        escrowContract.releasePayment(agreement.escrowId, _percentage);

        // If 100% finalized, complete the agreement
        if (_percentage == 100) {
            completeAgreement(_agreementId);
        }
    }

    // Add a function for buyers to dispute a milestone
    function disputeMilestone(
        bytes32 _agreementId,
        uint256 _percentage,
        string calldata _reason
    ) external whenNotPaused nonReentrant {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement is not active");
        require(msg.sender == agreement.buyer, "Only buyer can dispute");

        MilestoneCompletion storage milestone = agreement.milestones[
            _percentage
        ];
        require(milestone.timestamp > 0, "Milestone not reported yet");
        require(
            milestone.canDispute,
            "Milestone already finalized or disputed"
        );
        require(
            block.timestamp <= milestone.timestamp + DISPUTE_PERIOD,
            "Dispute period over"
        );

        milestone.disputed = true;
        milestone.canDispute = false;

        emit MilestoneDisputed(_agreementId, _percentage, _reason);
    }
}
