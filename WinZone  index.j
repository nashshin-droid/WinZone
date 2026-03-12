// pages/index.js
import { useState, useEffect } from "react";
import axios from "axios";
import bcrypt from "bcryptjs";
import { MongoClient } from "mongodb";

// ----------------- Backend DB & API -----------------
let client;
let usersCollection;
let settingsCollection;

async function connectDB() {
  if (!client) {
    client = new MongoClient(process.env.MONGODB_URI);
    await client.connect();
    const db = client.db("winzone");
    usersCollection = db.collection("users");
    settingsCollection = db.collection("settings");
  }
}

async function getUser(phone) {
  await connectDB();
  return usersCollection.findOne({ phone });
}

async function getOddsSettings() {
  await connectDB();
  let settings = await settingsCollection.findOne({ _id: "oddsSettings" });
  if (!settings) {
    await settingsCollection.insertOne({
      _id: "oddsSettings",
      football: {
        home: 1.05,
        draw: 1.05,
        away: 1.05,
        gg: 1.05,
        ng: 1.05,
        htft: 1.05,
        correct_score: 1.05
      }
    });
    settings = await settingsCollection.findOne({ _id: "oddsSettings" });
  }
  return settings.football;
}

async function settleBets(user) {
  await connectDB();
  let totalWin = 0;
  const oddsSettings = await getOddsSettings();

  for (let bet of user.bets) {
    if (bet.status === "pending") {
      try {
        if (bet.gameType === "football") {
          const res = await axios.get(
            `https://v3.football.api-sports.io/fixtures?id=${bet.match_id}`,
            { headers: { "x-apisports-key": process.env.API_FOOTBALL_KEY } }
          );
          const match = res.data.response[0];
          const winner =
            match.goals.home > match.goals.away
              ? "home"
              : match.goals.home < match.goals.away
              ? "away"
              : "draw";

          // Football markets with odds margin
          if (["home","draw","away"].includes(bet.type)) {
            if (winner === bet.type) totalWin += bet.stake * bet.odds * oddsSettings[bet.type];
          } else if (bet.type === "htft") {
            if (
              match.score.halftime.home === bet.htHome &&
              match.score.halftime.away === bet.htAway &&
              match.score.fulltime.home === bet.ftHome &&
              match.score.fulltime.away === bet.ftAway
            ) totalWin += bet.stake * bet.odds * oddsSettings.htft;
          } else if (bet.type === "gg") {
            if (match.goals.home > 0 && match.goals.away > 0) totalWin += bet.stake * bet.odds * oddsSettings.gg;
          } else if (bet.type === "ng") {
            if (match.goals.home === 0 || match.goals.away === 0) totalWin += bet.stake * bet.odds * oddsSettings.ng;
          } else if (bet.type === "correct_score") {
            if (match.goals.home === bet.correctHome && match.goals.away === bet.correctAway)
              totalWin += bet.stake * bet.odds * oddsSettings.correct_score;
          }
        } else if (bet.gameType === "aviator") {
          if (bet.cashoutMultiplier >= bet.randomMultiplier) totalWin += bet.stake * bet.randomMultiplier;
        } else if (bet.gameType === "jackpot") {
          if ((bet.type === "midweek" || bet.type === "grand") && bet.ticket === bet.winningNumber)
            totalWin += bet.stake * bet.odds;
        } else if (bet.gameType === "virtual") {
          if (bet.result === bet.type) totalWin += bet.stake * bet.odds;
        }

        await usersCollection.updateOne(
          { phone, "bets._id": bet._id },
          { $set: { "bets.$.status": "settled" } }
        );
      } catch {}
    }
  }
  if (totalWin > 0) await usersCollection.updateOne({ phone }, { $inc: { wallet: totalWin } });
  return totalWin;
}

// ----------------- API HANDLER -----------------
async function apiHandler(req, res) {
  const { action } = req.body || {};
  await connectDB();

  if (action === "signup") {
    const { email, phone, password } = req.body;
    if (!email || !phone || !password) return res.status(400).json({ error: "Missing fields" });
    const existing = await usersCollection.findOne({ $or: [{ email }, { phone }] });
    if (existing) return res.status(400).json({ error: "Email or phone already registered" });
    const hash = await bcrypt.hash(password, 10);
    await usersCollection.insertOne({ email, phone, passwordHash: hash, wallet: 0, bets: [], transactions: [] });
    return res.status(200).json({ message: "Signup successful" });
  }

  if (action === "login") {
    const { phone, password } = req.body;
    const user = await getUser(phone);
    if (!user) return res.status(400).json({ error: "Phone not found" });
    const match = await bcrypt.compare(password, user.passwordHash);
    if (!match) return res.status(400).json({ error: "Incorrect password" });
    return res.status(200).json({ message: "Login successful", wallet: user.wallet });
  }

  if (action === "deposit") {
    const { phone, amount } = req.body;
    try {
      const dodo = await axios.post(
        "https://api.dodopayments.com/v1/checkout",
        { amount, currency: "KES", return_url: process.env.DODO_PAYMENTS_RETURN_URL, customer: { name: phone } },
        { headers: { Authorization: `Bearer ${process.env.DODO_PAYMENTS_API_KEY}`, "Content-Type": "application/json" } }
      );
      await usersCollection.updateOne(
        { phone },
        { $push: { transactions: { type: "deposit", amount, status: "pending", dodo_payment_id: dodo.data.id, date: new Date() } } }
      );
      return res.status(200).json({ checkout_url: dodo.data.checkout_url });
    } catch { return res.status(500).json({ error: "Deposit failed" }); }
  }

  if (action === "withdraw") {
    const { phone, amount, simNumber } = req.body;
    const user = await getUser(phone);
    if (!user) return res.status(400).json({ error: "User not found" });
    if (user.wallet < amount) return res.status(400).json({ error: "Insufficient wallet" });
    await usersCollection.updateOne(
      { phone },
      { $inc: { wallet: -amount }, $push: { transactions: { type: "withdraw", amount, simNumber, status: "pending", date: new Date() } } }
    );
    return res.status(200).json({ message: `Withdrawal requested to ${simNumber}`, wallet: user.wallet - amount });
  }

  if (action === "place-bet") {
    const { phone, match_id, type, stake, odds, gameType, extra } = req.body;
    const user = await getUser(phone);
    if (!user) return res.status(400).json({ error: "User not found" });

    let betData = { _id: Math.random(), match_id, type, stake, status: "pending", odds, gameType, date: new Date() };
    if (extra) Object.assign(betData, extra);

    if (gameType === "aviator") betData.randomMultiplier = Math.random() * 10;
    if (gameType === "jackpot") {
      const today = new Date().getDay();
      if (type === "midweek") { betData.totalGames=15; betData.prize=2000000; betData.allowedBets=["home","draw","away"]; }
      else if (type === "grand") { betData.totalGames=17; betData.prize=5000000; betData.allowedBets=["home","draw","away"]; }
      betData.winningNumber = Math.floor(Math.random()*100);
    }
    if (gameType === "virtual") betData.result = ["home","draw","away"][Math.floor(Math.random()*3)];

    await usersCollection.updateOne(
      { phone },
      { $inc: { wallet: -stake }, $push: { bets: betData } }
    );
    return res.status(200).json({ message: "Bet placed", wallet: user.wallet - stake });
  }

  if (action === "settle-bets") {
    const { phone } = req.body;
    const user = await getUser(phone);
    if (!user) return res.status(400).json({ error: "User not found" });
    const totalWin = await settleBets(user);
    return res.status(200).json({ message: "Bets settled", totalWin, wallet: user.wallet + totalWin });
  }

  if (action === "admin-users") {
    const users = await usersCollection.find().toArray();
    return res.json(users);
  }

  if (action === "update-odds") {
    const { football } = req.body;
    await settingsCollection.updateOne({ _id: "oddsSettings" }, { $set: { football } });
    return res.status(200).json({ message: "Odds updated successfully" });
  }

  res.status(400).json({ error: "Invalid action" });
}

// ----------------- React Frontend -----------------
export default function Home() {
  const [page,setPage]=useState("signup");
  const [email,setEmail]=useState(""); 
  const [phone,setPhone]=useState(""); 
  const [password,setPassword]=useState("");
  const [wallet,setWallet]=useState(0); 
  const [amount,setAmount]=useState(""); 
  const [simNumber,setSimNumber]=useState("");
  const [matches,setMatches]=useState([]); 
  const [bets,setBets]=useState([]); 
  const [adminUsers,setAdminUsers]=useState([]);
  const [gameType,setGameType]=useState("football"); 
  const [selectedCountry,setSelectedCountry]=useState("All");
  const [odds, setOdds] = useState({});
  const isAdmin = phone===process.env.ADMIN_PHONE;

  useEffect(()=>{
    if(page==="dashboard") fetchMatches();
    if(isAdmin) fetchOdds();
    const interval=setInterval(()=>{ if(page==="dashboard") autoSettle(); },60000);
    return ()=>clearInterval(interval);
  },[page]);

  const fetchMatches = async () => {
    try {
      const url = selectedCountry==="All" 
        ? "https://v3.football.api-sports.io/fixtures?live=all" 
        : `https://v3.football.api-sports.io/fixtures?live=all&country=${selectedCountry}`;
      const res = await axios.get(url,{ headers:{ "x-apisports-key": process.env.API_FOOTBALL_KEY } });
      setMatches(res.data.response.map(m=>({
        match_id:m.fixture.id,
        home:m.teams.home.name,
        away:m.teams.away.name,
        status:m.fixture.status.short,
        odds:{
          home:1.5, draw:3, away:2,
          gg:1.8, ng:2, htft:5, correct_score:10
        }
      })));
    } catch {}
  };

  const autoSettle = async () => { 
    try { 
      const res = await axios.post("/api/winzone",{ action:"settle-bets", phone }); 
      if(res.data.totalWin>0) setWallet(wallet+res.data.totalWin); 
    } catch{} 
  };

  const fetchOdds = async () => {
    try {
      const res = await axios.post("/api/winzone",{ action:"admin-users" });
      setOdds(res.data[0]?.odds || { home:1.05, draw:1.05, away:1.05 });
    } catch {}
  };

  const handleOddsUpdate = async () => {
    await axios.post("/api/winzone",{ action:"update-odds", football: odds });
    alert("Odds updated!");
  };

  const handleSignup=async()=>{ try{ const res=await axios.post("/api/winzone",{ action:"signup", email, phone, password }); alert(res.data.message); setPage("login"); }catch(err){ alert(err.response?.data?.error||"Signup failed"); } };
  const handleLogin=async()=>{ try{ const res=await axios.post("/api/winzone",{ action:"login", phone, password }); alert(res.data.message); setWallet(res.data.wallet); setPage("dashboard"); if(isAdmin) fetchAdminUsers(); }catch{ alert("Login failed"); } };
  const fetchAdminUsers=async()=>{ try{ const res=await axios.post("/api/winzone",{ action:"admin-users" }); setAdminUsers(res.data); }catch{} };
  const handleDeposit=async()=>{ try{ const res=await axios.post("/api/winzone",{ action:"deposit", phone, amount:Number(amount) }); window.location.href=res.data.checkout_url; }catch{} };
  const handleWithdraw=async()=>{ try{ const res=await axios.post("/api/winzone",{ action:"withdraw", phone, amount:Number(amount), simNumber }); setWallet(res.data.wallet); alert(res.data.message); }catch{} };
  const addBet=(match,type,gt=gameType,extra=null)=>setBets([...bets,{ match_id:match.match_id, type, stake:10, odds:match.odds[type]||2, _id:Math.random(), gameType:gt, extra }]);
  const placeBets=async()=>{ for(let b of bets) await axios.post("/api/winzone",{ action:"place-bet", phone, match_id:b.match_id, type:b.type, stake:b.stake, odds:b.odds, gameType:b.gameType, extra:b.extra }); setWallet(wallet-bets.reduce((a,b)=>a+b.stake,0)); setBets([]); alert("Bets placed"); };

  return (
    <div style={{ maxWidth:"700px", margin:"50px auto", padding:"20px", backgroundColor:"#112240", color:"#fff", borderRadius:"10px" }}>
      <h2>WinZone Dashboard</h2>
      {page==="signup" && <div>
        <input placeholder="Email" value={email} onChange={e=>setEmail(e.target.value)} />
        <input placeholder="Phone" value={phone} onChange={e=>setPhone(e.target.value)} />
        <input placeholder="Password" type="password" value={password} onChange={e=>setPassword(e.target.value)} />
        <button onClick={handleSignup}>Signup</button>
        <button onClick={()=>setPage("login")}>Login</button>
      </div>}
      {page==="login" && <div>
        <input placeholder="Phone" value={phone} onChange={e=>setPhone(e.target.value)} />
        <input placeholder="Password" type="password" value={password} onChange={e=>setPassword(e.target.value)} />
        <button onClick={handleLogin}>Login</button>
      </div>}
      {page==="dashboard" && <div>
        <h3>Wallet: {wallet}</h3>
        {isAdmin && <div>
          <h3>Admin Odds Control</h3>
          {Object.keys(odds).map(key => (
            <div key={key}>
              <label>{key}: </label>
              <input type="number" step="0.01" value={odds[key]} onChange={e=>setOdds({...odds, [key]:parseFloat(e.target.value)})} />
            </div>
          ))}
          <button onClick={handleOddsUpdate}>Save Odds</button>
        </div>}
      </div>}
    </div>
  );
}