// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

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
    ) external;
}

contract EnergyToken is ERC20, Ownable {
    uint256 public rate = 2150; // Number of tokens per Ether

    /**
     * @dev Sets the values for {name}, {symbol}, and {initialAmount}.
     * Mints `initialAmount` tokens and assigns them to the deployer.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     * @param initialAmount The initial amount of tokens to mint.
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialAmount
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, initialAmount * 10 ** ERC20.decimals());
    }

    // Renamed event to avoid conflict with ERC20 Transfer
    event TransferAndCall(
        address indexed from,
        address indexed to,
        uint value,
        bytes data
    );

    /**
     * @dev Transfers tokens to a contract and then calls the contract's `onTokenTransfer` function.
     * @param to The address of the contract.
     * @param value The amount of tokens to transfer.
     * @param data Additional data with no specified format.
     * @return A boolean value indicating whether the operation succeeded.
     */
    function transferAndCall(
        address to,
        uint value,
        bytes calldata data
    ) public returns (bool) {
        _transfer(_msgSender(), to, value);
        if (isContract(to)) {
            IERC677Receiver receiver = IERC677Receiver(to);
            try receiver.onTokenTransfer(_msgSender(), value, data) {
                // success
            } catch {
                // handle failure
            }
            emit TransferAndCall(_msgSender(), to, value, data); // Updated event name
            return true;
        }
        return false;
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
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Allows users to buy tokens with Ether.
     * The number of tokens received is determined by the `rate`.
     */
    function buyTokens() external payable {
        require(_msgSender() != address(0), "Address must be non-zero");

        uint256 tokenAmount = (msg.value * rate) / 1 ether;

        require(tokenAmount > 0, "Not enough Ether provided");

        require(
            totalSupply() + tokenAmount <= cap(),
            "Not enough tokens available to mint"
        );
        _mint(msg.sender, tokenAmount);
    }

    /**
     * @dev Sets a new rate for tokens per Ether.
     * @param newRate The new rate of tokens per Ether.
     */
    function setRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "Rate must be greater than 0");
        rate = newRate;
    }

    /**
     * @dev Returns the maximum number of tokens that can be minted.
     * @return The cap on the token's total supply.
     */
    function cap() public view returns (uint256) {
        return 10000000000 * 10 ** decimals(); // Example cap, adjust as needed
    }

    /**
     * @dev Withdraws Ether from the contract to the owner's address.
     */
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
