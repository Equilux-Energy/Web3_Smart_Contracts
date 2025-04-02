// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC677Receiver {
    /**
     * @dev Handles the receipt of ERC677 tokens.
     * @param _sender The address which called `transferAndCall` function.
     * @param _value The amount of tokens transferred.
     * @param _data Additional data with no specified format.
     */
    function onTokenTransfer(
        address _sender,
        uint _value,
        bytes calldata _data
    ) external returns (bool);
}

contract EnergyToken is ERC20, ERC20Pausable, Ownable, ReentrancyGuard {
    uint256 public rate; // Number of tokens per Ether
    uint256 public immutable tokenCap; // Cap on total supply
    uint256 public maxPurchaseAmount; // Maximum tokens per transaction
    uint256 public rateChangeTimelock; // Timelock for rate changes

    event RateChanged(uint256 oldRate, uint256 newRate);
    event TokensPurchased(
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokenAmount
    );
    event WithdrawalMade(address indexed owner, uint256 amount);
    event TransferAndCall(
        address indexed from,
        address indexed to,
        uint value,
        bytes data
    );

    /**
     * @dev Sets the values for {name}, {symbol}, {initialAmount}, and {cap}.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     * @param initialAmount The initial amount of tokens to mint (in whole tokens).
     * @param cap_ The maximum cap for total supply (in whole tokens).
     * @param initialRate The initial exchange rate (tokens per ETH).
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialAmount,
        uint256 cap_,
        uint256 initialRate
    ) ERC20(name, symbol) Ownable(msg.sender) {
        require(cap_ > 0, "Cap must be greater than 0");
        require(initialAmount <= cap_, "Initial amount exceeds cap");
        require(initialRate > 0, "Rate must be greater than 0");

        uint256 initialTokens = initialAmount * 10 ** decimals();
        tokenCap = cap_ * 10 ** decimals();
        rate = initialRate;
        maxPurchaseAmount = 100000 * 10 ** decimals(); // Default 100,000 tokens

        _mint(msg.sender, initialTokens);
    }

    /**
     * @dev Transfers tokens to a contract and then calls the contract's `onTokenTransfer` function.
     * @param to The address of the recipient.
     * @param value The amount of tokens to transfer.
     * @param data Additional data with no specified format.
     * @return A boolean value indicating whether the operation succeeded.
     */
    function transferAndCall(
        address to,
        uint value,
        bytes calldata data
    ) public whenNotPaused returns (bool) {
        if (!isContract(to)) {
            // If not a contract, perform a normal transfer
            _transfer(_msgSender(), to, value);
            return true;
        }

        // If it's a contract, transfer and call onTokenTransfer
        _transfer(_msgSender(), to, value);
        IERC677Receiver receiver = IERC677Receiver(to);
        bool success = false;

        try receiver.onTokenTransfer(_msgSender(), value, data) returns (
            bool result
        ) {
            success = result;
        } catch {
            // Contract execution failed, but transfer was completed
            success = true; // We still return true since the transfer was successful
        }

        emit TransferAndCall(_msgSender(), to, value, data);
        return success;
    }

    /**
     * @dev Checks if an address is a contract.
     * @param addr The address to check.
     * @return A boolean value indicating whether the address is a contract.
     */
    function isContract(address addr) private view returns (bool) {
        uint size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /**
     * @dev Burns a specific amount of tokens.
     * @param amount The amount of tokens to be burned.
     */
    function burn(uint256 amount) external whenNotPaused {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Allows users to buy tokens with Ether.
     * The number of tokens received is determined by the `rate`.
     */
    function buyTokens() external payable nonReentrant whenNotPaused {
        require(_msgSender() != address(0), "Address must be non-zero");
        require(msg.value > 0, "Send ETH to buy tokens");

        uint256 tokenAmount = (msg.value * rate) / 1 ether;

        require(tokenAmount > 0, "Not enough ETH provided");
        require(
            tokenAmount <= maxPurchaseAmount,
            "Purchase exceeds maximum allowed"
        );
        require(
            totalSupply() + tokenAmount <= tokenCap,
            "Not enough tokens available to mint"
        );

        _mint(msg.sender, tokenAmount);
        emit TokensPurchased(msg.sender, msg.value, tokenAmount);
    }

    /**
     * @dev Sets a new rate for tokens per Ether.
     * @param newRate The new rate of tokens per Ether.
     */
    function setRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "Rate must be greater than 0");
        require(
            block.timestamp >= rateChangeTimelock,
            "Rate change is time-locked"
        );

        uint256 oldRate = rate;
        rate = newRate;
        rateChangeTimelock = block.timestamp + 1 days; // Lock rate changes for 24 hours

        emit RateChanged(oldRate, newRate);
    }

    /**
     * @dev Sets the maximum purchase amount per transaction.
     * @param _maxAmount The new maximum purchase amount.
     */
    function setMaxPurchaseAmount(uint256 _maxAmount) external onlyOwner {
        require(_maxAmount > 0, "Max purchase amount must be greater than 0");
        maxPurchaseAmount = _maxAmount;
    }

    /**
     * @dev Returns the maximum number of tokens that can be minted.
     * @return The cap on the token's total supply.
     */
    function cap() public view returns (uint256) {
        return tokenCap;
    }

    /**
     * @dev Withdraws Ether from the contract to the owner's address.
     * @param amount The amount of ETH to withdraw (0 for all)
     */
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        uint256 withdrawAmount = amount == 0 ? address(this).balance : amount;
        require(
            withdrawAmount <= address(this).balance,
            "Insufficient balance"
        );

        payable(owner()).transfer(withdrawAmount);
        emit WithdrawalMade(owner(), withdrawAmount);
    }

    /**
     * @dev Pause token transfers and purchases.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause token transfers and purchases.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Required override for _update to support ERC20Pausable
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }
}
