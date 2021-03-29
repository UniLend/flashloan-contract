pragma solidity 0.6.2;
// SPDX-License-Identifier: MIT

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";

import "./IFlashLoanReceiver.sol";
import "./EthAddressLib.sol";
import "./UnilendFDonation.sol";


library Math {
    function min(uint x, uint y) internal pure returns (uint z) {
        z = x < y ? x : y;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}






contract UFlashLoanPool is ERC20 {
    using SafeMath for uint256;
    
    address public token;
    address payable public core;
    
    
    constructor(
        address _token,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) public {
        token = _token;
        
        core = payable(msg.sender);
    }
    
    modifier onlyCore {
        require(
            core == msg.sender,
            "Not Permitted"
        );
        _;
    }
    
    
    
    function calculateShare(uint _totalShares, uint _totalAmount, uint _amount) internal pure returns (uint){
        if(_totalShares == 0){
            return Math.sqrt(_amount.mul( _amount ));
        } else {
            return (_amount).mul( _totalShares ).div( _totalAmount );
        }
    }
    
    function getShareValue(uint _totalAmount, uint _totalSupply, uint _amount) internal pure returns (uint){
        return ( _amount.mul(_totalAmount) ).div( _totalSupply );
    }
    
    function getShareByValue(uint _totalAmount, uint _totalSupply, uint _valueAmount) internal pure returns (uint){
        return ( _valueAmount.mul(_totalSupply) ).div( _totalAmount );
    }
    
    
    function deposit(address _recipient, uint amount) external onlyCore returns(uint) {
        uint _totalSupply = totalSupply();
        
        uint tokenBalance;
        if(EthAddressLib.ethAddress() == token){
            tokenBalance = address(core).balance;
        } 
        else {
            tokenBalance = IERC20(token).balanceOf(core);
        }
        
        uint ntokens = calculateShare(_totalSupply, tokenBalance.sub(amount), amount);
        
        require(ntokens > 0, 'Insufficient Liquidity Minted');
        
        // MINT uTokens
        _mint(_recipient, ntokens);
        
        return ntokens;
    }
    
    
    function redeem(address _recipient, uint tok_amount) external onlyCore returns(uint) {
        require(tok_amount > 0, 'Insufficient Liquidity Burned');
        require(balanceOf(_recipient) >= tok_amount, "Balance Exeeds Requested");
        
        uint tokenBalance;
        if(EthAddressLib.ethAddress() == token){
            tokenBalance = address(core).balance;
        } 
        else {
            tokenBalance = IERC20(token).balanceOf(core);
        }
        
        uint poolAmount = getShareValue(tokenBalance, totalSupply(), tok_amount);
        
        require(tokenBalance >= poolAmount, "Not enough Liquidity");
        
        // BURN uTokens
        _burn(_recipient, tok_amount);
        
        return poolAmount;
    }
    
    
    function redeemUnderlying(address _recipient, uint amount) external onlyCore returns(uint) {
        uint tokenBalance;
        if(EthAddressLib.ethAddress() == token){
            tokenBalance = address(core).balance;
        } 
        else {
            tokenBalance = IERC20(token).balanceOf(core);
        }
        
        uint tok_amount = getShareByValue(tokenBalance, totalSupply(), amount);
        
        require(tok_amount > 0, 'Insufficient Liquidity Burned');
        require(balanceOf(_recipient) >= tok_amount, "Balance Exeeds Requested");
        require(tokenBalance >= amount, "Not enough Liquidity");
        
        // BURN uTokens
        _burn(_recipient, tok_amount);
        
        return tok_amount;
    }
    
    
    function balanceOfUnderlying(address _address) public view returns (uint _bal) {
        uint _balance = balanceOf(_address);
        
        if(_balance > 0){
            uint tokenBalance;
            if(EthAddressLib.ethAddress() == token){
                tokenBalance = address(core).balance;
            } 
            else {
                tokenBalance = IERC20(token).balanceOf(core);
            }
            
            address donationAddress = UnilendFlashLoanCore( core ).donationAddress();
            uint _balanceDonation = UnilendFDonation( donationAddress ).getCurrentRelease(token, block.timestamp);
            uint _totalPoolAmount = tokenBalance.add(_balanceDonation);
            
            _bal = getShareValue(_totalPoolAmount, totalSupply(), _balance);
        } 
    }
}


contract UnilendFlashLoanCore is Context, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;
    
    address public admin;
    address payable public distributorAddress;
    address public donationAddress;
    
    mapping(address => address) public Pools;
    mapping(address => address) public Assets;
    uint public poolLength;
    
    
    uint256 private FLASHLOAN_FEE_TOTAL = 5;
    uint256 private FLASHLOAN_FEE_PROTOCOL = 3000;
    
    
    constructor() public {
        admin = msg.sender;
    }
    
    
    /**
    * @dev emitted when a flashloan is executed
    * @param _target the address of the flashLoanReceiver
    * @param _reserve the address of the reserve
    * @param _amount the amount requested
    * @param _totalFee the total fee on the amount
    * @param _protocolFee the part of the fee for the protocol
    * @param _timestamp the timestamp of the action
    **/
    event FlashLoan(
        address indexed _target,
        address indexed _reserve,
        uint256 _amount,
        uint256 _totalFee,
        uint256 _protocolFee,
        uint256 _timestamp
    );
    
    event PoolCreated(address indexed token, address pool, uint);
    
    /**
    * @dev emitted during a redeem action.
    * @param _reserve the address of the reserve
    * @param _user the address of the user
    * @param _amount the amount to be deposited
    * @param _timestamp the timestamp of the action
    **/
    event RedeemUnderlying(
        address indexed _reserve,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );
    
    /**
    * @dev emitted on deposit
    * @param _reserve the address of the reserve
    * @param _user the address of the user
    * @param _amount the amount to be deposited
    * @param _timestamp the timestamp of the action
    **/
    event Deposit(
        address indexed _reserve,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );
    
    /**
    * @dev only lending pools configurator can use functions affected by this modifier
    **/
    modifier onlyAdmin {
        require(
            admin == msg.sender,
            "The caller must be a admin"
        );
        _;
    }
    
    /**
    * @dev functions affected by this modifier can only be invoked if the provided _amount input parameter
    * is not zero.
    * @param _amount the amount provided
    **/
    modifier onlyAmountGreaterThanZero(uint256 _amount) {
        require(_amount > 0, "Amount must be greater than 0");
        _;
    }
    
    receive() payable external {}
    
    /**
    * @dev returns the fee applied to a flashloan and the portion to redirect to the protocol, in basis points.
    **/
    function getFlashLoanFeesInBips() public view returns (uint256, uint256) {
        return (FLASHLOAN_FEE_TOTAL, FLASHLOAN_FEE_PROTOCOL);
    }
    
    /**
    * @dev gets the bulk uToken contract address for the reserves
    * @param _reserves the array of reserve address
    * @return the address of the uToken contract
    **/
    function getPools(address[] calldata _reserves) external view returns (address[] memory) {
        address[] memory _addresss = new address[](_reserves.length);
        address[] memory _reserves_ = _reserves;
        
        for (uint i=0; i<_reserves_.length; i++) {
            _addresss[i] = Pools[_reserves_[i]];
        }
        
        return _addresss;
    }
    
    
    
    
    /**
    * @dev set new admin for contract.
    * @param _admin the address of new admin
    **/
    function setAdmin(address _admin) external onlyAdmin {
        require(_admin != address(0), "UnilendV1: ZERO ADDRESS");
        admin = _admin;
    }
    
    /**
    * @dev set new distributor address.
    * @param _address new address
    **/
    function setDistributorAddress(address payable _address) external onlyAdmin {
        require(_address != address(0), "UnilendV1: ZERO ADDRESS");
        distributorAddress = _address;
    }
    
    /**
    * @dev set new flash loan fees.
    * @param _newFeeTotal total fee
    * @param _newFeeProtocol protocol fee
    **/
    function setFlashLoanFeesInBips(uint _newFeeTotal, uint _newFeeProtocol) external onlyAdmin returns (bool) {
        require(_newFeeTotal > 0 && _newFeeTotal < 10000, "UnilendV1: INVALID TOTAL FEE RANGE");
        require(_newFeeProtocol > 0 && _newFeeProtocol < 10000, "UnilendV1: INVALID PROTOCOL FEE RANGE");
        
        FLASHLOAN_FEE_TOTAL = _newFeeTotal;
        FLASHLOAN_FEE_PROTOCOL = _newFeeProtocol;
        
        return true;
    }
    

    /**
    * @dev transfers to the user a specific amount from the reserve.
    * @param _reserve the address of the reserve where the transfer is happening
    * @param _user the address of the user receiving the transfer
    * @param _amount the amount being transferred
    **/
    function transferToUser(address _reserve, address payable _user, uint256 _amount) internal {
        require(_user != address(0), "UnilendV1: USER ZERO ADDRESS");
        
        if (_reserve != EthAddressLib.ethAddress()) {
            ERC20(_reserve).safeTransfer(_user, _amount);
        } else {
            //solium-disable-next-line
            (bool result, ) = _user.call{value: _amount, gas: 50000}("");
            require(result, "Transfer of ETH failed");
        }
    }
    
    /**
    * @dev transfers to the protocol fees of a flashloan to the fees collection address
    * @param _token the address of the token being transferred
    * @param _amount the amount being transferred
    **/
    function transferFlashLoanProtocolFeeInternal(address _token, uint256 _amount) internal {
        if (_token != EthAddressLib.ethAddress()) {
            ERC20(_token).safeTransfer(distributorAddress, _amount);
        } else {
            (bool result, ) = distributorAddress.call{value: _amount, gas: 50000}("");
            require(result, "Transfer of ETH failed");
        }
    }
    
    
    /**
    * @dev allows smartcontracts to access the liquidity of the pool within one transaction,
    * as long as the amount taken plus a fee is returned. NOTE There are security concerns for developers of flashloan receiver contracts
    * that must be kept into consideration.
    * @param _receiver The address of the contract receiving the funds. The receiver should implement the IFlashLoanReceiver interface.
    * @param _reserve the address of the principal reserve
    * @param _amount the amount requested for this flashloan
    **/
    function flashLoan(address _receiver, address _reserve, uint256 _amount, bytes calldata _params)
        external
        nonReentrant
        onlyAmountGreaterThanZero(_amount)
    {
        //check that the reserve has enough available liquidity
        uint256 availableLiquidityBefore = _reserve == EthAddressLib.ethAddress()
            ? address(this).balance
            : IERC20(_reserve).balanceOf(address(this));

        require(
            availableLiquidityBefore >= _amount,
            "There is not enough liquidity available to borrow"
        );

        (uint256 totalFeeBips, uint256 protocolFeeBips) = getFlashLoanFeesInBips();
        //calculate amount fee
        uint256 amountFee = _amount.mul(totalFeeBips).div(10000);

        //protocol fee is the part of the amountFee reserved for the protocol - the rest goes to depositors
        uint256 protocolFee = amountFee.mul(protocolFeeBips).div(10000);
        require(
            amountFee > 0 && protocolFee > 0,
            "The requested amount is too small for a flashLoan."
        );

        //get the FlashLoanReceiver instance
        IFlashLoanReceiver receiver = IFlashLoanReceiver(_receiver);

        //transfer funds to the receiver
        transferToUser(_reserve, payable(_receiver), _amount);

        //execute action of the receiver
        receiver.executeOperation(_reserve, _amount, amountFee, _params);

        //check that the actual balance of the core contract includes the returned amount
        uint256 availableLiquidityAfter = _reserve == EthAddressLib.ethAddress()
            ? address(this).balance
            : IERC20(_reserve).balanceOf(address(this));

        require(
            availableLiquidityAfter == availableLiquidityBefore.add(amountFee),
            "The actual balance of the protocol is inconsistent"
        );
        
        transferFlashLoanProtocolFeeInternal(_reserve, protocolFee);

        //solium-disable-next-line
        emit FlashLoan(_receiver, _reserve, _amount, amountFee, protocolFee, block.timestamp);
    }
    
    
    
    
    
    /**
    * @dev deposits The underlying asset into the reserve. A corresponding amount of the overlying asset (uTokens) is minted.
    * @param _reserve the address of the reserve
    * @param _amount the amount to be deposited
    **/
    function deposit(address _reserve, uint _amount) external 
        payable
        nonReentrant
        onlyAmountGreaterThanZero(_amount)
    returns(uint mintedTokens) {
        require(Pools[_reserve] != address(0), 'UnilendV1: POOL NOT FOUND');
        
        UnilendFDonation(donationAddress).releaseTokens(_reserve);
        
        address _user = msg.sender;
        
        if (_reserve != EthAddressLib.ethAddress()) {
            require(msg.value == 0, "User is sending ETH along with the ERC20 transfer.");
            
            uint reserveBalance = IERC20(_reserve).balanceOf(address(this));
            
            ERC20(_reserve).safeTransferFrom(_user, address(this), _amount);
            
            _amount = ( IERC20(_reserve).balanceOf(address(this)) ).sub(reserveBalance);
        } else {
            require(msg.value >= _amount, "The amount and the value sent to deposit do not match");

            if (msg.value > _amount) {
                //send back excess ETH
                uint256 excessAmount = msg.value.sub(_amount);
                
                (bool result, ) = _user.call{value: excessAmount, gas: 50000}("");
                require(result, "Transfer of ETH failed");
            }
        }
        
        mintedTokens = UFlashLoanPool(Pools[_reserve]).deposit(msg.sender, _amount);
        
        emit Deposit(_reserve, msg.sender, _amount, block.timestamp);
    }
    
    
    /**
    * @dev Redeems the uTokens for underlying assets.
    * @param _reserve the address of the reserve
    * @param _amount the amount uTokens to be redeemed
    **/
    function redeem(address _reserve, uint _amount) external returns(uint redeemTokens) {
        require(Pools[_reserve] != address(0), 'UnilendV1: POOL NOT FOUND');
        
        UnilendFDonation(donationAddress).releaseTokens(_reserve);
        
        redeemTokens = UFlashLoanPool(Pools[_reserve]).redeem(msg.sender, _amount);
        
        //transfer funds to the user
        transferToUser(_reserve, payable(msg.sender), redeemTokens);
        
        emit RedeemUnderlying(_reserve, msg.sender, redeemTokens, block.timestamp);
    }
    
    /**
    * @dev Redeems the underlying amount of assets.
    * @param _reserve the address of the reserve
    * @param _amount the underlying amount to be redeemed
    **/
    function redeemUnderlying(address _reserve, uint _amount) external returns(uint token_amount) {
        require(Pools[_reserve] != address(0), 'UnilendV1: POOL NOT FOUND');
        
        UnilendFDonation(donationAddress).releaseTokens(_reserve);
        
        token_amount = UFlashLoanPool(Pools[_reserve]).redeemUnderlying(msg.sender, _amount);
        
        //transfer funds to the user
        transferToUser(_reserve, payable(msg.sender), _amount);
        
        emit RedeemUnderlying(_reserve, msg.sender, _amount, block.timestamp);
    }
    
    
    
    /**
    * @dev Creates pool for asset.
    * This function is executed by the overlying aToken contract in response to a redeem action.
    * @param _reserve the address of the reserve
    **/
    function createPool(address _reserve) public returns (address) {
        require(Pools[_reserve] == address(0), 'UnilendV1: POOL ALREADY CREATED');
        
        ERC20 asset = ERC20(_reserve);
        
        string memory uTokenName;
        string memory uTokenSymbol;
        
        if(_reserve == EthAddressLib.ethAddress()){
            uTokenName = string(abi.encodePacked("UnilendV1 - ETH"));
            uTokenSymbol = string(abi.encodePacked("uETH"));
        } 
        else {
            uTokenName = string(abi.encodePacked("UnilendV1 - ", asset.name()));
            uTokenSymbol = string(abi.encodePacked("u", asset.symbol()));
        }
        
        UFlashLoanPool _poolMeta = new UFlashLoanPool(_reserve, uTokenName, uTokenSymbol);
        
        address _poolAddress = address(_poolMeta);
        
        Pools[_reserve] = _poolAddress;
        Assets[_poolAddress] = _reserve;
        
        poolLength++;
        
        emit PoolCreated(_reserve, _poolAddress, poolLength);
        
        return _poolAddress;
    }
    
    /**
    * @dev Creates donation contract (one-time).
    **/
    function createDonationContract() external returns (address) {
        require(donationAddress == address(0), 'UnilendV1: DONATION ADDRESS ALREADY CREATED');
        
        UnilendFDonation _donationMeta = new UnilendFDonation();
        donationAddress = address(_donationMeta);
        
        return donationAddress;
    }
}
