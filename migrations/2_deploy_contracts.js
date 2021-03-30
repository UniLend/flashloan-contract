const FlashLoanCore = artifacts.require("UnilendFlashLoanCore")


module.exports = async function(deployer) {
  deployer
  .then(async () => {
    // Deploy factory contract
    await deployer.deploy(FlashLoanCore)
    const FlashLoanCoreContract = await FlashLoanCore.deployed()
    console.log("Unilend FlashLoanCore deployement done:", FlashLoanCoreContract.address)
    
    await FlashLoanCoreContract.createDonationContract();  
    console.log("Unilend FlashLoanCore Donation Contract Created")
  })
}
