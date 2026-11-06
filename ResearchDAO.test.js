const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const E = ethers.parseEther;

describe("ResearchDAO", () => {
  let dao, tok, admin, rev, res, a, b, c;
  beforeEach(async () => {
    [admin, rev, res, a, b, c] = await ethers.getSigners();
    tok = await (await ethers.getContractFactory("MockToken")).deploy("BOT");
    dao = await (await ethers.getContractFactory("ResearchDAO")).deploy();
    for (const f of [a, b]) { await tok.mint(f.address, E("1000")); await tok.connect(f).approve(dao.target, E("1000")); }
    await dao.setReviewer(rev.address, true);
    await dao.createRound("R1", tok.target, E("1000"), 100, 100, 2, 1);
    await dao.connect(res).registerResearcher("Dr. Ada", "ipfs://profile", ethers.id("p"));
    await dao.connect(res).submitProposal(0, "Study", "Biology", "ipfs://m", ethers.id("m"), ["M1", "M2"], [E("100"), E("200")]);
  });
  const approve = async () => {
    await dao.connect(a).vote(0, true); await dao.connect(b).vote(0, true); await dao.connect(rev).review(0, true);
    await time.increase(101); await dao.finalizeVoting(0);
  };
  const fund = async () => { await dao.connect(a).contribute(0, E("150")); await dao.connect(b).contribute(0, E("150")); };

  it("prevents double voting", async () => {
    await dao.connect(a).vote(0, true);
    await expect(dao.connect(a).vote(0, true)).to.be.revertedWith("voted");
  });
  it("rejects without quorum/reviewer approval", async () => {
    await dao.connect(a).vote(0, true); await time.increase(101); await dao.finalizeVoting(0);
    expect((await dao.getProposal(0)).status).to.equal(5);
  });
  it("blocks unauthorized funding and over-budget contributions", async () => {
    await expect(dao.connect(a).contribute(0, E("1"))).to.be.revertedWith("not funding");
    await approve();
    await expect(dao.connect(a).contribute(0, E("301"))).to.be.revertedWith("over budget");
  });
  it("runs full flow and prevents duplicate milestone payment", async () => {
    await approve(); await fund();
    await dao.connect(res).submitMilestone(0, 0, ethers.id("e"), "ipfs://e");
    await dao.connect(rev).verifyMilestone(0, 0, true);
    await dao.authorizePayment(0, 0);
    expect(await tok.balanceOf(res.address)).to.equal(E("100"));
    await expect(dao.authorizePayment(0, 0)).to.be.revertedWith("not payable");
    await expect(dao.connect(c).authorizePayment(0, 0)).to.be.revertedWith("admin");
    await dao.connect(res).submitMilestone(0, 1, ethers.id("e2"), "ipfs://e2");
    await dao.connect(rev).verifyMilestone(0, 1, true); await dao.authorizePayment(0, 1);
    expect((await dao.getProposal(0)).status).to.equal(4);
  });
  it("refunds pro-rata after cancellation", async () => {
    await approve(); await fund();
    await dao.connect(res).submitMilestone(0, 0, ethers.id("e"), ""); await dao.connect(rev).verifyMilestone(0, 0, true);
    await dao.authorizePayment(0, 0); await dao.cancel(0);
    await dao.connect(a).refund(0); // 150 * (300-100)/300 = 100
    expect(await tok.balanceOf(a.address)).to.equal(E("950"));
    await expect(dao.connect(a).refund(0)).to.be.revertedWith("claimed");
  });
  it("refunds failed funding", async () => {
    await approve(); await dao.connect(a).contribute(0, E("50"));
    await time.increase(101); await dao.finalizeFunding(0);
    await dao.connect(a).refund(0); expect(await tok.balanceOf(a.address)).to.equal(E("1000"));
  });
});
