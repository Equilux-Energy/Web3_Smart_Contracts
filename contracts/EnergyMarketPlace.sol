// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./EnergyToken.sol";
import "./EnergyEscrow.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

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
    // Define roles for contract access
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    bytes32 public constant USER_ROLE = keccak256("USER_ROLE");
    // Add a dispute period
    uint256 public constant DISPUTE_PERIOD = 24 hours;

    // Funding timeout: buyer must fund within 24 hours
    uint256 public constant FUNDING_TIMEOUT = 1 hours;

    // Reference to the energy token
    EnergyToken public energyToken;

    // Reference to the escrow contract
    EnergyEscrow public escrowContract;

    // Maximum username length to prevent gas issues
    uint256 public constant MAX_USERNAME_LENGTH = 32;

    // Mapping to store usernames by address
    mapping(address => string) public usernames;
    
    // Mapping from username to address to check if username exists
    mapping(string => address) private usernameToAddress;
    
    // New struct to track user statistics and history
    struct UserProfile {
        uint256 offersCreated;
        uint256 offersNegotiated;
        uint256 agreementsCompleted;
        uint256 agreementsCancelled;
        uint256 disputesInitiated;
        uint256 disputesWon;
        uint256 totalEnergyTraded;
        uint256 totalValueTraded;
        uint256 lastActivityTimestamp;
    }
    
    // Mapping to store user profiles
    mapping(address => UserProfile) public userProfiles;

    // New event for username registration
    event UsernameRegistered(address indexed user, string username);
    event UsernameUpdated(address indexed user, string oldUsername, string newUsername);

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
        string creatorUsername;    // Store username for easier identification
        OfferType offerType;
        uint256 energyAmount; // in kWh
        uint256 pricePerUnit; // price in tokens per kWh
        uint256 totalPrice;
        uint256 startTime;
        uint256 endTime;
        OfferStatus status;
        address counterparty; // Address of the trading partner once agreed
        string counterpartyUsername; // Username of counterparty
        uint256 createdAt;
    }

    // Struct to represent a negotiation message
    struct NegotiationMessage {
        address sender;
        string senderUsername;    // Add sender username
        uint256 timestamp;
        string message;
        uint256 proposedPrice; // 0 if not proposing a new price
        uint256 proposedEnergyAmount; // 0 if not proposing a new amount
    }

    // Add a new struct to track negotiations by counterparty
    struct OfferNegotiation {
        bool isActive;
        address counterparty;
        string counterpartyUsername;  // Add counterparty username
        uint256 latestProposalIndex; // Index into the negotiations array
        uint256 startedAt;
    }

    // Struct to represent a trade agreement
    struct Agreement {
        bytes32 id;
        bytes32 offerId;
        address buyer;
        string buyerUsername;     // Add buyer username
        address seller;
        string sellerUsername;    // Add seller username
        uint256 finalEnergyAmount;
        uint256 finalTotalPrice;
        uint256 agreedAt;
        bytes32 escrowId;
        bool isActive;
        uint256 fundingDeadline;
        bool funded;
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

    // Add mapping to track active negotiations per offer
    mapping(bytes32 => mapping(address => OfferNegotiation))
        public offerNegotiations;
    mapping(bytes32 => address[]) public offerNegotiators;

    // Events
    event OfferCreated(
        bytes32 indexed offerId,
        address indexed creator,
        string creatorUsername,
        OfferType offerType
    );
    event OfferUpdated(bytes32 indexed offerId, OfferStatus status);
    event NegotiationMessageAdded(bytes32 indexed offerId, address sender, string senderUsername);
    event AgreementCreated(
        bytes32 indexed agreementId,
        bytes32 indexed offerId,
        address buyer,
        string buyerUsername,
        address seller,
        string sellerUsername
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

    event AgreementFunded(bytes32 indexed agreementId);
    event AgreementCancelled(bytes32 indexed agreementId, string reason);

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
     * @dev Register or update a username for the calling user
     * @param _username The username to register
     */
    function registerUsername(string calldata _username) external whenNotPaused onlyRole(USER_ROLE) {
        require(bytes(_username).length > 0, "Username cannot be empty");
        require(bytes(_username).length <= MAX_USERNAME_LENGTH, "Username too long");
        require(usernameToAddress[_username] == address(0) || usernameToAddress[_username] == msg.sender, 
                "Username already taken");
                
        // Check if user is updating an existing username
        string memory oldUsername = usernames[msg.sender];
        
        if (bytes(oldUsername).length > 0) {
            // Clear old username mapping
            delete usernameToAddress[oldUsername];
            emit UsernameUpdated(msg.sender, oldUsername, _username);
        } else {
            emit UsernameRegistered(msg.sender, _username);
        }
        
        // Update mappings
        usernames[msg.sender] = _username;
        usernameToAddress[_username] = msg.sender;
        
        // Initialize user profile if it doesn't exist
        if (userProfiles[msg.sender].lastActivityTimestamp == 0) {
            userProfiles[msg.sender] = UserProfile({
                offersCreated: 0,
                offersNegotiated: 0,
                agreementsCompleted: 0,
                agreementsCancelled: 0,
                disputesInitiated: 0,
                disputesWon: 0,
                totalEnergyTraded: 0,
                totalValueTraded: 0,
                lastActivityTimestamp: block.timestamp
            });
        } else {
            userProfiles[msg.sender].lastActivityTimestamp = block.timestamp;
        }
    }
    
    /**
     * @dev Get a user's username
     * @param _user The address of the user
     * @return The username associated with the address, or empty if not registered
     */
    function getUsernameByAddress(address _user) public view returns (string memory) {
        return usernames[_user];
    }
    
    /**
     * @dev Get a user's address by their username
     * @param _username The username to look up
     * @return The address associated with the username, or zero address if not registered
     */
    function getAddressByUsername(string calldata _username) public view returns (address) {
        return usernameToAddress[_username];
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
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(USER_ROLE)
        returns (bytes32 offerId)
    {
        require(_energyAmount > 0, "Energy amount must be > 0");
        require(_pricePerUnit > 0, "Price per unit must be > 0");
        require(_endTime > _startTime, "End time must be after start time");
        require(_startTime > block.timestamp, "Start time must be in future");
        
        // Ensure user has registered a username
        string memory creatorUsername = usernames[msg.sender];
        require(bytes(creatorUsername).length > 0, "Must register username first");

        uint256 totalPrice = _energyAmount * _pricePerUnit;
        offerId = generateUniqueId(msg.sender, uint256(uint160(_offerType)));
        offers[offerId] = Offer({
            id: offerId,
            creator: msg.sender,
            creatorUsername: creatorUsername,
            offerType: _offerType,
            energyAmount: _energyAmount,
            pricePerUnit: _pricePerUnit,
            totalPrice: totalPrice,
            startTime: _startTime,
            endTime: _endTime,
            status: OfferStatus.ACTIVE,
            counterparty: address(0),
            counterpartyUsername: "",
            createdAt: block.timestamp
        });

        userOffers[msg.sender].push(offerId);
        activeOfferIds.push(offerId);
        activeOfferIndexes[offerId] = activeOfferIds.length - 1;
        
        // Update user profile statistics
        UserProfile storage profile = userProfiles[msg.sender];
        profile.offersCreated += 1;
        profile.lastActivityTimestamp = block.timestamp;
        
        emit OfferCreated(offerId, msg.sender, creatorUsername, _offerType);
        return offerId;
    }

    function updateOffer(
        bytes32 _offerId,
        uint256 _energyAmount,
        uint256 _pricePerUnit,
        uint256 _startTime,
        uint256 _endTime
    ) external whenNotPaused nonReentrant onlyRole(USER_ROLE) {
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
        
        // Update user profile's last activity timestamp
        userProfiles[msg.sender].lastActivityTimestamp = block.timestamp;

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
    ) external whenNotPaused nonReentrant onlyRole(USER_ROLE) {
        Offer storage offer = offers[_offerId];
        require(offer.id == _offerId, "Offer does not exist");
        require(
            offer.status == OfferStatus.ACTIVE ||
                offer.status == OfferStatus.NEGOTIATING,
            "Offer not open for negotiation"
        );
        
        // Get username of sender
        string memory senderUsername = usernames[msg.sender];
        require(bytes(senderUsername).length > 0, "Must register username first");

        // Create or update negotiation record for this counterparty
        if (
            !offerNegotiations[_offerId][msg.sender].isActive &&
            msg.sender != offer.creator
        ) {
            offerNegotiations[_offerId][msg.sender] = OfferNegotiation({
                isActive: true,
                counterparty: msg.sender,
                counterpartyUsername: senderUsername,
                latestProposalIndex: negotiations[_offerId].length, // Will be updated
                startedAt: block.timestamp
            });
            offerNegotiators[_offerId].push(msg.sender);
            
            // Update user profile stats for negotiation
            UserProfile storage profile = userProfiles[msg.sender];
            profile.offersNegotiated += 1;
            profile.lastActivityTimestamp = block.timestamp;
        }

        // Update offer status if this is the first negotiation
        if (offer.status == OfferStatus.ACTIVE) {
            offer.status = OfferStatus.NEGOTIATING;
            emit OfferUpdated(_offerId, OfferStatus.NEGOTIATING);
        }

        // Add the negotiation message with username
        uint256 newIndex = negotiations[_offerId].length;
        negotiations[_offerId].push(
            NegotiationMessage({
                sender: msg.sender,
                senderUsername: senderUsername,
                timestamp: block.timestamp,
                message: _message,
                proposedPrice: _proposedPrice,
                proposedEnergyAmount: _proposedEnergyAmount
            })
        );

        // Update the latest proposal index for this negotiator
        if (msg.sender != offer.creator) {
            offerNegotiations[_offerId][msg.sender]
                .latestProposalIndex = newIndex;
        }
        
        // Update last activity timestamp
        userProfiles[msg.sender].lastActivityTimestamp = block.timestamp;

        emit NegotiationMessageAdded(_offerId, msg.sender, senderUsername);
    }

    /**
     * @dev Accept a negotiation and proceed to agreement
     * @param _offerId ID of the offer
     * @param _counterparty Address of the counterparty
     */
    function acceptNegotiation(
        bytes32 _offerId,
        address _counterparty
    ) external whenNotPaused nonReentrant {
        Offer storage offer = offers[_offerId];

        require(offer.id == _offerId, "Offer does not exist");
        require(
            offer.status == OfferStatus.NEGOTIATING,
            "Offer is not in negotiation"
        );
        require(
            msg.sender == offer.creator,
            "Only offer creator can accept negotiation"
        );
        require(
            offerNegotiations[_offerId][_counterparty].isActive,
            "No active negotiation with counterparty"
        );
        
        // Get counterparty username
        string memory counterpartyUsername = usernames[_counterparty];
        require(bytes(counterpartyUsername).length > 0, "Counterparty must have username");

        // Set the counterparty and update status to AGREED
        offer.counterparty = _counterparty;
        offer.counterpartyUsername = counterpartyUsername;
        offer.status = OfferStatus.AGREED;

        // Get the latest proposal details from this counterparty
        uint256 latestIndex = offerNegotiations[_offerId][_counterparty]
            .latestProposalIndex;
        NegotiationMessage memory latestProposal = negotiations[_offerId][
            latestIndex
        ];

        if (latestProposal.proposedPrice > 0) {
            offer.pricePerUnit = latestProposal.proposedPrice;
            offer.totalPrice =
                latestProposal.proposedPrice *
                offer.energyAmount;
        }
        if (latestProposal.proposedEnergyAmount > 0) {
            offer.energyAmount = latestProposal.proposedEnergyAmount;
            offer.totalPrice =
                offer.pricePerUnit *
                latestProposal.proposedEnergyAmount;
        }
        
        // Update user profile's last activity timestamp
        userProfiles[msg.sender].lastActivityTimestamp = block.timestamp;

        emit OfferUpdated(_offerId, OfferStatus.AGREED);
    }

    /**
     * @dev Cancel a negotiation and revert to active status
     * @param _offerId ID of the offer
     * @param _counterparty Address of the counterparty
     */
    function cancelNegotiation(
        bytes32 _offerId,
        address _counterparty
    ) external whenNotPaused nonReentrant {
        Offer storage offer = offers[_offerId];

        require(offer.id == _offerId, "Offer does not exist");
        require(
            msg.sender == offer.creator,
            "Only the offer creator can cancel negotiation"
        );
        require(
            offer.status == OfferStatus.NEGOTIATING,
            "Offer is not in negotiation"
        );

        // If counterparty is zero address, cancel all negotiations
        if (_counterparty == address(0)) {
            // Remove all active negotiations
            for (uint i = 0; i < offerNegotiators[_offerId].length; i++) {
                address negotiator = offerNegotiators[_offerId][i];
                if (offerNegotiations[_offerId][negotiator].isActive) {
                    offerNegotiations[_offerId][negotiator].isActive = false;
                }
            }

            // Reset status back to ACTIVE
            offer.status = OfferStatus.ACTIVE;
            offer.counterparty = address(0); // Clear counterparty
            offer.counterpartyUsername = ""; // Clear counterparty username
        } else {
            // Cancel specific negotiation
            require(
                offerNegotiations[_offerId][_counterparty].isActive,
                "No active negotiation with counterparty"
            );
            offerNegotiations[_offerId][_counterparty].isActive = false;

            // Check if there are any active negotiations left
            bool hasActiveNegotiations = false;
            for (uint i = 0; i < offerNegotiators[_offerId].length; i++) {
                address negotiator = offerNegotiators[_offerId][i];
                if (offerNegotiations[_offerId][negotiator].isActive) {
                    hasActiveNegotiations = true;
                    break;
                }
            }

            // If no active negotiations left, reset offer status to ACTIVE
            if (!hasActiveNegotiations) {
                offer.status = OfferStatus.ACTIVE;
                offer.counterparty = address(0);
                offer.counterpartyUsername = "";
            }
        }
        
        // Update user profile's last activity timestamp
        userProfiles[msg.sender].lastActivityTimestamp = block.timestamp;

        emit OfferUpdated(_offerId, offer.status);
    }

    /**
     * @dev Create a trade agreement from an offer
     * @param _offerId ID of the offer
     * @return agreementId ID of the created agreement
     */
    function createAgreement(
        bytes32 _offerId
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(USER_ROLE)
        returns (bytes32)
    {
        Offer storage offer = offers[_offerId];
        uint256 _finalPrice = offer.totalPrice;
        uint256 _finalEnergyAmount = offer.energyAmount;
        require(offer.id == _offerId, "Offer does not exist");
        require(
            offer.status == OfferStatus.AGREED,
            "Offer must be agreed upon before creating an agreement"
        );

        require(_finalEnergyAmount > 0, "Energy amount must be > 0");
        
        // Get caller's username
        string memory callerUsername = usernames[msg.sender];
        require(bytes(callerUsername).length > 0, "Must register username first");

        address buyer;
        string memory buyerUsername;
        address seller;
        string memory sellerUsername;
        
        if (offer.offerType == OfferType.BUY) {
            buyer = offer.creator;
            buyerUsername = offer.creatorUsername;
            seller = msg.sender;
            sellerUsername = callerUsername;
            require(msg.sender != buyer, "Cannot agree to your own offer");
        } else {
            seller = offer.creator;
            sellerUsername = offer.creatorUsername;
            buyer = msg.sender;
            buyerUsername = callerUsername;
            require(msg.sender != seller, "Cannot agree to your own offer");
        }

        bytes32 agreementId = generateUniqueId(
            msg.sender,
            uint256(_finalPrice)
        );

        // Create a new escrow record for this agreement.
        bytes32 escrowId = escrowContract.createEscrow(
            buyer,
            seller,
            _finalEnergyAmount,
            _finalPrice
        );

        // Remove the automatic funding for BUY offers
        bool isFunded = false;

        // Update offer status and link the counterparty.
        offer.status = OfferStatus.AGREED;
        offer.counterparty = msg.sender;
        offer.counterpartyUsername = callerUsername;
        _removeFromActiveOffers(_offerId);

        Agreement storage newAgreement = agreements[agreementId];
        newAgreement.id = agreementId;
        newAgreement.offerId = _offerId;
        newAgreement.buyer = buyer;
        newAgreement.buyerUsername = buyerUsername;
        newAgreement.seller = seller;
        newAgreement.sellerUsername = sellerUsername;
        newAgreement.finalEnergyAmount = _finalEnergyAmount;
        newAgreement.finalTotalPrice = _finalPrice;
        newAgreement.agreedAt = block.timestamp;
        newAgreement.fundingDeadline = block.timestamp + FUNDING_TIMEOUT;
        newAgreement.escrowId = escrowId;
        newAgreement.isActive = true;
        newAgreement.funded = isFunded;

        userAgreements[buyer].push(agreementId);
        userAgreements[seller].push(agreementId);
        
        // Update activity timestamp for both parties
        userProfiles[buyer].lastActivityTimestamp = block.timestamp;
        userProfiles[seller].lastActivityTimestamp = block.timestamp;
        
        emit AgreementCreated(agreementId, _offerId, buyer, buyerUsername, seller, sellerUsername);
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
     * @dev Funds an existing agreement.
     * @param _agreementId The unique identifier of the agreement to be funded.
     */
    function fundAgreement(
        bytes32 _agreementId
    ) external whenNotPaused nonReentrant onlyRole(USER_ROLE) {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement not active");
        require(!agreement.funded, "Agreement already funded");
        require(
            block.timestamp <= agreement.fundingDeadline,
            "Funding deadline passed"
        );
        require(msg.sender == agreement.buyer, "Only buyer can fund");

        require(
            energyToken.transferFrom(
                agreement.buyer,
                address(escrowContract),
                agreement.finalTotalPrice
            ),
            "Token transfer failed"
        );
        agreement.funded = true;
        escrowContract.startEscrow(agreement.escrowId);
        
        // Update buyer profile's last activity timestamp
        userProfiles[agreement.buyer].lastActivityTimestamp = block.timestamp;
        
        emit AgreementFunded(_agreementId);
    }

    /**
     * @dev Start the energy transfer process
     * @param _agreementId ID of the agreement
     */
    function startEnergyTransfer(
        bytes32 _agreementId
    ) external whenNotPaused nonReentrant onlyRole(USER_ROLE) {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement not active");
        require(agreement.funded, "Agreement not funded");
        require(msg.sender == agreement.buyer, "Only buyer can start transfer");

        // At this point, energy transfer (and the subsequent escrow releases) can proceed.
        // For example, update offer status and perform any necessary preparations.
        Offer storage offer = offers[agreement.offerId];
        offer.status = OfferStatus.IN_PROGRESS;
        
        // Update user profile's last activity timestamp
        userProfiles[msg.sender].lastActivityTimestamp = block.timestamp;

        emit EnergyDeliveryProgress(_agreementId, 0);
    }

    /**
     * @notice Cancels an unfunded agreement if the funding deadline has expired.
     * @param _agreementId The ID of the agreement to cancel.
     */
    function cancelUnfundedAgreement(
        bytes32 _agreementId
    ) external whenNotPaused nonReentrant onlyRole(USER_ROLE) {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement not active");
        require(!agreement.funded, "Agreement already funded");
        require(
            block.timestamp > agreement.fundingDeadline,
            "Funding deadline not expired"
        );

        // Allow buyer, seller, or admin to cancel.
        require(
            msg.sender == agreement.buyer ||
                msg.sender == agreement.seller ||
                hasRole(ADMIN_ROLE, msg.sender) ||
                hasRole(MODERATOR_ROLE, msg.sender),
            "Not authorized to cancel"
        );

        agreement.isActive = false;
        // Reactivate the original offer.
        Offer storage offer = offers[agreement.offerId];
        offer.status = OfferStatus.ACTIVE;
        offer.counterparty = address(0);
        offer.counterpartyUsername = "";
        activeOfferIds.push(offer.id);
        activeOfferIndexes[offer.id] = activeOfferIds.length - 1;
        
        // Update user statistics
        userProfiles[agreement.buyer].agreementsCancelled += 1;
        userProfiles[agreement.seller].agreementsCancelled += 1;
        userProfiles[msg.sender].lastActivityTimestamp = block.timestamp;

        emit AgreementCancelled(_agreementId, "Funding deadline expired");
        emit OfferUpdated(offer.id, OfferStatus.ACTIVE);
    }

    /**
     * @dev Report energy delivery progress
     * @param _agreementId ID of the agreement
     * @param _percentage Percentage of energy delivered (25, 50, 75, or 100)
     */
    function reportEnergyDelivery(
        bytes32 _agreementId,
        uint256 _percentage
    ) external whenNotPaused nonReentrant onlyRole(MODERATOR_ROLE) {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement is not active");
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
        
        // Update user statistics
        UserProfile storage buyerProfile = userProfiles[agreement.buyer];
        UserProfile storage sellerProfile = userProfiles[agreement.seller];
        
        buyerProfile.agreementsCompleted += 1;
        sellerProfile.agreementsCompleted += 1;
        
        // Track total energy and value traded
        buyerProfile.totalEnergyTraded += agreement.finalEnergyAmount;
        sellerProfile.totalEnergyTraded += agreement.finalEnergyAmount;
        buyerProfile.totalValueTraded += agreement.finalTotalPrice;
        sellerProfile.totalValueTraded += agreement.finalTotalPrice;
        
        buyerProfile.lastActivityTimestamp = block.timestamp;
        sellerProfile.lastActivityTimestamp = block.timestamp;

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
    ) external whenNotPaused nonReentrant onlyRole(MODERATOR_ROLE) {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        require(agreement.isActive, "Agreement is not active");

        Offer storage offer = offers[agreement.offerId];

        // Process refund through escrow
        escrowContract.processRefund(agreement.escrowId);

        agreement.isActive = false;
        offer.status = OfferStatus.CANCELLED;

        emit TradeRefunded(_agreementId, _reason);
        emit OfferUpdated(agreement.offerId, OfferStatus.CANCELLED);
    }

    /**
     * @dev Get all active offers with username information
     */
    function getActiveOffers()
        external
        view
        onlyRole(USER_ROLE)
        returns (bytes32[] memory)
    {
        return activeOfferIds;
    }

    /**
     * @dev Get active offer details with usernames
     * @param _offerId The ID of the offer to get details for
     */
    function getOfferDetails(bytes32 _offerId) 
        external 
        view
        onlyRole(USER_ROLE) 
        returns (
            bytes32 id,
            address creator,
            string memory creatorUsername,
            OfferType offerType,
            uint256 energyAmount,
            uint256 pricePerUnit,
            uint256 totalPrice,
            uint256 startTime,
            uint256 endTime,
            OfferStatus status,
            address counterparty,
            string memory counterpartyUsername,
            uint256 createdAt
        ) 
    {
        Offer storage offer = offers[_offerId];
        return (
            offer.id,
            offer.creator,
            offer.creatorUsername,
            offer.offerType,
            offer.energyAmount,
            offer.pricePerUnit,
            offer.totalPrice,
            offer.startTime,
            offer.endTime,
            offer.status,
            offer.counterparty,
            offer.counterpartyUsername,
            offer.createdAt
        );
    }

    /**
     * @dev Get negotiation messages for an offer
     * @param _offerId ID of the offer
     * @return Array of negotiation messages
     */
    function getNegotiationMessages(
        bytes32 _offerId
    ) external view onlyRole(USER_ROLE) returns (NegotiationMessage[] memory) {
        return negotiations[_offerId];
    }

    /**
     * @dev Get offers created by a user
     * @param _user Address of the user
     * @return Array of offer IDs created by the user
     */
    function getUserOffers(
        address _user
    ) external view onlyRole(USER_ROLE) returns (bytes32[] memory) {
        return userOffers[_user];
    }

    /**
     * @dev Get agreements associated with a user
     * @param _user Address of the user
     * @return Array of agreement IDs associated with the user
     */
    function getUserAgreements(
        address _user
    ) external view onlyRole(USER_ROLE) returns (bytes32[] memory) {
        return userAgreements[_user];
    }
    
    /**
     * @dev Get agreement details including usernames
     * @param _agreementId The ID of the agreement to get details for
     */
    function getAgreementDetails(bytes32 _agreementId)
        external
        view
        onlyRole(USER_ROLE)
        returns (
            bytes32 id,
            bytes32 offerId,
            address buyer,
            string memory buyerUsername,
            address seller,
            string memory sellerUsername,
            uint256 finalEnergyAmount,
            uint256 finalTotalPrice,
            uint256 agreedAt,
            bool isActive,
            bool funded
        )
    {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");
        
        return (
            agreement.id,
            agreement.offerId,
            agreement.buyer,
            agreement.buyerUsername,
            agreement.seller,
            agreement.sellerUsername,
            agreement.finalEnergyAmount,
            agreement.finalTotalPrice,
            agreement.agreedAt,
            agreement.isActive,
            agreement.funded
        );
    }
    
    /**
     * @dev Get user trading statistics
     * @param _user Address of the user
     */
    function getUserStats(address _user)
        external
        view
        returns (
            string memory username,
            uint256 offersCreated,
            uint256 offersNegotiated,
            uint256 agreementsCompleted,
            uint256 agreementsCancelled,
            uint256 disputesInitiated,
            uint256 disputesWon,
            uint256 totalEnergyTraded,
            uint256 totalValueTraded,
            uint256 lastActivityTimestamp
        )
    {
        UserProfile storage profile = userProfiles[_user];
        return (
            usernames[_user],
            profile.offersCreated,
            profile.offersNegotiated,
            profile.agreementsCompleted,
            profile.agreementsCancelled,
            profile.disputesInitiated,
            profile.disputesWon,
            profile.totalEnergyTraded,
            profile.totalValueTraded,
            profile.lastActivityTimestamp
        );
    }

    // New function to get all active negotiators for an offer with usernames
    function getOfferNegotiators(
        bytes32 _offerId
    ) external view returns (address[] memory addresses, string[] memory usernames) {
        uint256 activeNegotiatorCount = 0;
        
        // Count active negotiators first
        for (uint i = 0; i < offerNegotiators[_offerId].length; i++) {
            address negotiator = offerNegotiators[_offerId][i];
            if (offerNegotiations[_offerId][negotiator].isActive) {
                activeNegotiatorCount++;
            }
        }
        
        // Create arrays of correct size
        addresses = new address[](activeNegotiatorCount);
        usernames = new string[](activeNegotiatorCount);
        
        // Fill arrays with data
        uint256 index = 0;
        for (uint i = 0; i < offerNegotiators[_offerId].length; i++) {
            address negotiator = offerNegotiators[_offerId][i];
            if (offerNegotiations[_offerId][negotiator].isActive) {
                addresses[index] = negotiator;
                usernames[index] = usernames[negotiator];
                index++;
            }
        }
        
        return (addresses, usernames);
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
     * @dev Grant user role to an address and optionally set username
     * @param _account Address to grant the role to
     * @param _username Optional username to set for the user (empty string to skip)
     */
    function addUser(address _account, string calldata _username) external onlyRole(ADMIN_ROLE) {
        grantRole(USER_ROLE, _account);
        
        // If a username is provided, register it for the user
        if (bytes(_username).length > 0) {
            require(bytes(_username).length <= MAX_USERNAME_LENGTH, "Username too long");
            require(usernameToAddress[_username] == address(0), "Username already taken");
            
            usernames[_account] = _username;
            usernameToAddress[_username] = _account;
            
            // Initialize user profile
            userProfiles[_account] = UserProfile({
                offersCreated: 0,
                offersNegotiated: 0,
                agreementsCompleted: 0,
                agreementsCancelled: 0,
                disputesInitiated: 0,
                disputesWon: 0,
                totalEnergyTraded: 0,
                totalValueTraded: 0,
                lastActivityTimestamp: block.timestamp
            });
            
            emit UsernameRegistered(_account, _username);
        }
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
    ) external whenNotPaused nonReentrant onlyRole(USER_ROLE) {
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
        
        // Update user statistics
        userProfiles[msg.sender].disputesInitiated += 1;
        userProfiles[msg.sender].lastActivityTimestamp = block.timestamp;

        emit MilestoneDisputed(_agreementId, _percentage, _reason);
    }

    function resolveDispute(
        bytes32 _agreementId,
        uint256 _percentage,
        bool buyerWins
    ) external onlyRole(ADMIN_ROLE) {
        Agreement storage agreement = agreements[_agreementId];
        require(agreement.id == _agreementId, "Agreement does not exist");

        if (buyerWins) {
            escrowContract.processRefund(agreement.escrowId);
            agreement.isActive = false;
            // Update user statistics
            userProfiles[agreement.buyer].disputesWon += 1;
            emit TradeRefunded(_agreementId, "Admin resolved in buyer's favor");
        } else {
            escrowContract.releasePayment(agreement.escrowId, _percentage);
            emit EnergyDeliveryProgress(_agreementId, _percentage);
        }
        
        // Update activity timestamps
        userProfiles[agreement.buyer].lastActivityTimestamp = block.timestamp;
        userProfiles[agreement.seller].lastActivityTimestamp = block.timestamp;
    }
}