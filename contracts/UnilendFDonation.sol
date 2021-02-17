pragma solidity ^0.6.2;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";

import "./EthAddressLib.sol";


contract UnilendFDonation {
    using SafeMath for uint256;
    
    uint public defaultReleaseRate;
    mapping(address => uint) releaseRate;
    mapping(address => uint) public lastReleased;
    address public core;
    
    constructor() public {
        core = msg.sender;
        defaultReleaseRate = 11574074074075; // ~1% / day
    }
    
    
    modifier onlyCore {
        require(
            core == msg.sender,
            "Not Permitted"
        );
        _;
    }
    
    
    event NewDonation(address indexed donator, uint amount);
    event Released(address indexed to, uint amount);
    event ReleaseRate(address indexed token, uint rate);
    
    
    
    function balanceOfToken(address _token) external view returns(uint) {
        return IERC20(_token).balanceOf(address(this));
    }
    
    function getReleaseRate(address _token) public view returns (uint) {
        if(releaseRate[_token] > 0){
            return releaseRate[_token];
        } 
        else {
            return defaultReleaseRate;
        }
    }
    
    function getCurrentRelease(address _token, uint timestamp) public view returns (uint availRelease){
        // uint tokenBalance = IERC20(_token).balanceOf( address(this) );
        uint tokenBalance;
        if(EthAddressLib.ethAddress() == _token){
            tokenBalance = address(this).balance;
        } 
        else {
            tokenBalance = IERC20(_token).balanceOf( address(this) );
        }
        
        uint remainingRate = ( timestamp.sub( lastReleased[_token] ) ).mul( getReleaseRate(_token) );
        uint maxRate = 100 * 10**18;
        
        if(remainingRate > maxRate){ remainingRate = maxRate; }
        availRelease = ( tokenBalance.mul( remainingRate )).div(10**20);
    }
    
    
    function donate(address _token, uint amount) external returns(bool) {
        require(amount > 0, "Amount can't be zero");
        releaseTokens(_token);
        
        IERC20(_token).transferFrom(msg.sender, address(this), amount);
        
        emit NewDonation(msg.sender, amount);
        
        return true;
    }
    
    function setReleaseRate(address _token, uint _newRate) external onlyCore {
        releaseTokens(_token);
        
        releaseRate[_token] = _newRate;
        
        emit ReleaseRate(_token, _newRate);
    }
    
    function releaseTokens(address _token) public {
        uint tokenBalance;
        if(EthAddressLib.ethAddress() == _token){
            tokenBalance = address(this).balance;
        } 
        else {
            tokenBalance = IERC20(_token).balanceOf( address(this) );
        }
        
        
        if(tokenBalance > 0){
            uint remainingRate = ( block.timestamp.sub( lastReleased[_token] ) ).mul( getReleaseRate(_token) );
            uint maxRate = 100 * 10**18;
            
            if(remainingRate > maxRate){ remainingRate = maxRate; }
            uint totalReleased = ( tokenBalance.mul( remainingRate )).div(10**20);
            
            if(totalReleased > 0){
                IERC20(_token).transfer(core, totalReleased);
                
                emit Released(core, totalReleased);
            }
        }
        
        lastReleased[_token] = block.timestamp;
    }
}