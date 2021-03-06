// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "./tokens/ERC721.sol";
import "./tokens/ERC20.sol";
import "./interfaces/IStrategy.sol";

import { console } from "./test/Console.sol";

///======================================================================================================================================
// Vaults are designed to be human readeable and as minimal as possible
// 
// 1e4 = basis points calculation && 1e10 = floating point scalar
///======================================================================================================================================

contract BaseVault is ERC721 {

///======================================================================================================================================
/// Data Struct
///======================================================================================================================================

    struct Deposits {
        uint256 amount; 
        uint256 tracker; //sum of delta(deposit) * yeildPerDeposit || SCALED
    }

    struct MetaData {
        string name;
        address vaultAddress;
        uint256 withdrawable;
        uint256 id;
        uint256 vaultType;
    }

///======================================================================================================================================
/// Accounting State
///======================================================================================================================================

    // tokenID => Deposits
    mapping(uint256 => Deposits) public deposits;

    //sum of yeild/totalDeposits scaled by 1e10
    uint256 public yeildPerDeposit;

    uint256 public totalDeposits;

    // used to account for random deposits
    uint256 internal lastKnownContractBalance;
    
    // used when calculating rewards and yield Strategy deposits
    uint256 internal lastKnownStrategyTotal;

    uint256 internal depositedToStrat;

///======================================================================================================================================
/// Everything Else
///======================================================================================================================================

    ERC20 public vaultToken;

    uint256 internal isInitialized;

    IStrategy public strat;

    uint256 public currentId;

///======================================================================================================================================
/// Init
///======================================================================================================================================

    // constructor() {
    //     // call init on impl on deployment
    //     baseInit("Init", "Init", address(0), address(0));
    // }

    function baseInit(string memory _name, string memory _symbol, address _token, address strategy) public {
        require(isInitialized == 0, "Already Initialized");

        _nftInit(_name, _symbol);

        strat = IStrategy(strategy);

        vaultToken = ERC20(_token);

        isInitialized = 1;

    }


///======================================================================================================================================
/// Overrideable Public Functions
///
/// Individual use case logic can done here 
///======================================================================================================================================

    function mintNewNft(uint256 amount) public virtual returns (uint256) {
        return _mintNewNFT(amount);
    }

    function depositToId(uint256 amount, uint256 id) public virtual {
        _depositToId(amount, id);
    }

    function withdrawFromId(uint256 id, uint256 amount) public virtual {
        _withdrawFromId(amount, id);
    }

    function burnNFTAndWithdrawl(uint256 id) public virtual {

        uint256 claimable = withdrawableById(id);
        _withdrawFromId(claimable, id);

        // erc721
        _burn(id);

    }

    function withdrawableById(uint256 id)
        public view
        virtual returns (uint256 claimId) 
    {

        return deposits[id].amount + yieldPerId(id);

    }

///======================================================================================================================================
/// Internal Logic
///
/// distributeYield() must always be done before
/// deposits to get accurate yield calculations
///======================================================================================================================================

    function _mintNewNFT(uint256 amount) internal returns (uint256) {

        uint256 id;

        unchecked {
            id = _mint(msg.sender, ++currentId);
        }

        if (totalDeposits > 0) {
            distributeYeild();
        }

        deposits[id].amount = amount;
        deposits[id].tracker += amount * yeildPerDeposit;

        totalDeposits += amount;
        lastKnownContractBalance += amount;

        //ensure token reverts on failed
        vaultToken.transferFrom(msg.sender, address(this), amount);

        return id;

    }

    function _depositToId(uint256 amount, uint256 id) internal {

        // trusted contract
        require(msg.sender == ownerOf[id]); 

        if (totalDeposits > 0) {
            distributeYeild();
        }

        deposits[id].amount += amount;
        deposits[id].tracker += amount * yeildPerDeposit;
        
        totalDeposits += amount;
        lastKnownContractBalance += amount;

        //ensure token reverts on failed
        vaultToken.transferFrom(msg.sender, address(this), amount); 

    }

    function _withdrawFromId(uint256 amount, uint256 id) internal {

        // Alaways distribute yield 
        distributeYeild();

        require(
            msg.sender == ownerOf[id] && 
            amount <= withdrawableById(id)
        ); 

        uint256 balanceCheck = vaultToken.balanceOf(address(this));
        uint256 principalWithdrawn;
        uint256 userYield = yieldPerId(id);

        if (amount > userYield) {

            principalWithdrawn = amount - userYield;
            deposits[id].amount -= principalWithdrawn;
            totalDeposits -= principalWithdrawn;
            
            // all user Yield is harvested therefore at the current
            // point in time the user is not entitled to any yield
            deposits[id].tracker = deposits[id].amount * yeildPerDeposit;

        } else {
            
            // user yield still remains therefore principal not affected
            // just add nonclaimable to current tracker
            deposits[id].tracker += amount * 1e10;
    
        }
        
        uint256 short = amount > balanceCheck ? amount - balanceCheck : 0;
        if (short > 0) {

            withdrawFromStrat(short);
            depositedToStrat -= principalWithdrawn;

        }

        vaultToken.transfer(msg.sender, amount); 
    }

///======================================================================================================================================
/// Strategy
///======================================================================================================================================

    //total possible deposited to strat is currently set at 50%
    function initStrat() public {

        require(address(strat) != address(0), "No Strategy");

        // 50% of total deposits
        uint256 half = (totalDeposits * 5000) / 10000;
        uint256 depositable = half - depositedToStrat;

        depositedToStrat += depositable;
        lastKnownStrategyTotal += depositable;
        lastKnownContractBalance -= depositable;

        vaultToken.approve(address(strat), depositable);
        strat.deposit(depositable);

    }

    //internal, only called when balanceOf(address(this)) < withdraw requested
    function withdrawFromStrat(uint256 amountNeeded) internal {

        strat.withdrawl(amountNeeded);
        lastKnownStrategyTotal -= amountNeeded;
        
    }

///======================================================================================================================================
/// Yield
///======================================================================================================================================

    // gets yeild from strategy contract
    // called before deposits and withdrawls
    function distributeYeild() public virtual {

        uint256 unclaimedYield = 
            vaultToken.balanceOf(address(this)) - lastKnownContractBalance;
        lastKnownContractBalance += unclaimedYield;
        
        uint256 strategyYield = address(strat) != address(0) ? 
            strat.withdrawlableVaultToken() - lastKnownStrategyTotal : 0;
        lastKnownStrategyTotal += strategyYield;

        yeildPerDeposit += ((unclaimedYield + strategyYield) * 1e10) / totalDeposits;
        
    }

    function yieldPerId(uint256 id) public view returns (uint256) {

        
        uint256 pre = (deposits[id].amount * yeildPerDeposit) / 1e10;
        return pre - (deposits[id].tracker / 1e10);

    }

///======================================================================================================================================
/// Token metadata
///======================================================================================================================================

    function tokenURI(uint256 id) 
        public view virtual
        returns (MetaData memory) {

        return MetaData(name, address(this), withdrawableById(id), id, 0);

    }
}
