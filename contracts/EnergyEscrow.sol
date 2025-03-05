// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./EnergyToken.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title EnergyEscrow
 * @dev Handles the phased payments in the energy trading platform
 */
contract EnergyEscrow is ReentrancyGuard, Pausable, Ownable {
    // Reference to the energy token
    EnergyToken public energyToken;

    // Struct to represent an escrow
    struct Escrow {
        bytes32 id;
        address buyer;
        address seller;
        uint256 energyAmount;
        uint256 totalAmount;
        uint256 amountPaid;
        uint256 createdAt;
        bool isActive;
        mapping(uint256 => bool) milestoneReleased; // Maps percentage (25, 50, 75, 100) to release status
    }

    // Counter for nonce (used to ensure unique IDs)
    uint256 private nonce = 0;

    // Mapping from ID to Escrow
    mapping(bytes32 => Escrow) public escrows;

    // Marketplace contract address - only this contract can create and manage escrows
    address public marketplaceContract;

    // Events
    event EscrowCreated(
        bytes32 indexed escrowId,
        address buyer,
        address seller,
        uint256 totalAmount
    );
    event EscrowStarted(bytes32 indexed escrowId);
    event MilestoneReleased(
        bytes32 indexed escrowId,
        uint256 percentage,
        uint256 amount
    );
    event EscrowCompleted(bytes32 indexed escrowId);
    event EscrowRefunded(bytes32 indexed escrowId, uint256 amount);

    // Modifier to restrict functions to marketplace contract only
    modifier onlyMarketplace() {
        require(
            msg.sender == marketplaceContract,
            "Caller is not the marketplace"
        );
        _;
    }

    /**
     * @dev Constructor to set the energy token address
     * @param _tokenAddress Address of the energy token contract
     */
    constructor(address _tokenAddress) Ownable(msg.sender) {
        energyToken = EnergyToken(_tokenAddress);
        marketplaceContract = msg.sender; // Set deploying contract as marketplace
    }

    /**
     * @dev Generate a unique hash-based ID
     * @param _buyer Address of the buyer
     * @param _seller Address of the seller
     * @param _salt Additional salt value
     * @return bytes32 hash that serves as ID
     */
    function generateUniqueId(
        address _buyer,
        address _seller,
        uint256 _salt
    ) internal returns (bytes32) {
        nonce++;
        return
            keccak256(
                abi.encodePacked(
                    _buyer,
                    _seller,
                    block.timestamp,
                    _salt,
                    nonce,
                    blockhash(block.number - 1)
                )
            );
    }

    /**
     * @dev Create a new escrow
     * @param _buyer Address of the buyer
     * @param _seller Address of the seller
     * @param _energyAmount Amount of energy in kWh
     * @param _totalAmount Total amount to be paid
     * @return escrowId ID of the created escrow
     */
    function createEscrow(
        address _buyer,
        address _seller,
        uint256 _energyAmount,
        uint256 _totalAmount
    ) external onlyMarketplace whenNotPaused nonReentrant returns (bytes32) {
        bytes32 escrowId = generateUniqueId(_buyer, _seller, _energyAmount);

        Escrow storage escrow = escrows[escrowId];
        escrow.id = escrowId;
        escrow.buyer = _buyer;
        escrow.seller = _seller;
        escrow.energyAmount = _energyAmount;
        escrow.totalAmount = _totalAmount;
        escrow.amountPaid = 0;
        escrow.createdAt = block.timestamp;
        escrow.isActive = false; // Inactive until funds are deposited

        emit EscrowCreated(escrowId, _buyer, _seller, _totalAmount);

        return escrowId;
    }

    /**
     * @dev Start an escrow after funds have been received
     * @param _escrowId ID of the escrow
     */
    function startEscrow(
        bytes32 _escrowId
    ) external onlyMarketplace whenNotPaused nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.id == _escrowId, "Escrow does not exist");
        require(!escrow.isActive, "Escrow is already active");

        // Check that funds have been received
        uint256 balance = energyToken.balanceOf(address(this));
        require(balance >= escrow.totalAmount, "Insufficient funds received");

        escrow.isActive = true;

        emit EscrowStarted(_escrowId);
    }

    /**
     * @dev Release payment for a milestone
     * @param _escrowId ID of the escrow
     * @param _percentage Percentage of energy delivered (25, 50, 75, or 100)
     */
    function releasePayment(
        bytes32 _escrowId,
        uint256 _percentage
    ) external onlyMarketplace whenNotPaused nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.id == _escrowId, "Escrow does not exist");
        require(escrow.isActive, "Escrow is not active");
        require(
            _percentage == 25 ||
                _percentage == 50 ||
                _percentage == 75 ||
                _percentage == 100,
            "Percentage must be 25, 50, 75, or 100"
        );
        require(
            !escrow.milestoneReleased[_percentage],
            "This milestone has already been released"
        );

        // Ensure milestones are released in order
        if (_percentage > 25) {
            require(
                escrow.milestoneReleased[_percentage - 25],
                "Previous milestone has not been released"
            );
        }

        // Calculate amount to release
        uint256 amountToRelease = escrow.totalAmount / 4; // 25% of the total

        // Mark milestone as released
        escrow.milestoneReleased[_percentage] = true;

        // Update amount paid
        escrow.amountPaid += amountToRelease;

        // Transfer tokens to seller
        require(
            energyToken.transfer(escrow.seller, amountToRelease),
            "Token transfer failed"
        );

        emit MilestoneReleased(_escrowId, _percentage, amountToRelease);

        // If 100% released, complete the escrow
        if (_percentage == 100) {
            escrow.isActive = false;
            emit EscrowCompleted(_escrowId);
        }
    }

    /**
     * @dev Process refund for incomplete delivery
     * @param _escrowId ID of the escrow
     */
    function processRefund(
        bytes32 _escrowId
    ) external onlyMarketplace whenNotPaused nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.id == _escrowId, "Escrow does not exist");
        require(escrow.isActive, "Escrow is not active");

        // Calculate remaining amount
        uint256 remainingAmount = escrow.totalAmount - escrow.amountPaid;

        // Mark escrow as inactive
        escrow.isActive = false;

        // Transfer remaining tokens back to buyer
        if (remainingAmount > 0) {
            require(
                energyToken.transfer(escrow.buyer, remainingAmount),
                "Token transfer failed"
            );
            emit EscrowRefunded(_escrowId, remainingAmount);
        }
    }

    /**
     * @dev Get the escrow details
     * @param _escrowId ID of the escrow
     * @return buyer Address of the buyer
     * @return seller Address of the seller
     * @return energyAmount Amount of energy
     * @return totalAmount Total amount to be paid
     * @return amountPaid Amount already paid
     * @return isActive Whether the escrow is active
     */
    function getEscrowDetails(
        bytes32 _escrowId
    )
        external
        view
        returns (
            address buyer,
            address seller,
            uint256 energyAmount,
            uint256 totalAmount,
            uint256 amountPaid,
            bool isActive
        )
    {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.id == _escrowId, "Escrow does not exist");

        return (
            escrow.buyer,
            escrow.seller,
            escrow.energyAmount,
            escrow.totalAmount,
            escrow.amountPaid,
            escrow.isActive
        );
    }

    /**
     * @dev Check if a milestone has been released
     * @param _escrowId ID of the escrow
     * @param _percentage Milestone percentage
     * @return True if milestone has been released
     */
    function isMilestoneReleased(
        bytes32 _escrowId,
        uint256 _percentage
    ) external view returns (bool) {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.id == _escrowId, "Escrow does not exist");

        return escrow.milestoneReleased[_percentage];
    }

    /**
     * @notice Updates the address of the marketplace contract.
     * @dev This function can only be called by the owner of the contract.
     * @param _newMarketplace The address of the new marketplace contract.
     */
    function updateMarketplaceContract(
        address _newMarketplace
    ) external onlyOwner {
        require(_newMarketplace != address(0), "Invalid marketplace address");
        marketplaceContract = _newMarketplace;
    }

    /**
     * @dev Pause the contract
     * Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause the contract
     * Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency withdrawal of tokens
     * @param _token Token address to withdraw
     * @param _to Address to send tokens to
     * @param _amount Amount to withdraw
     * Only callable by owner in emergency situations
     */
    function emergencyWithdraw(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(_to != address(0), "Cannot withdraw to zero address");
        EnergyToken(_token).transfer(_to, _amount);
    }
}
