import Phaser from 'phaser';
import MarketScene from './market';
import { io } from 'socket.io-client';
import FishingScene from './fishing';

const socket = io('http://localhost:8787');

// --- Auth & wallet HUD ---
async function ensureToken(): Promise<string> {
  let token = localStorage.getItem("token") || "";
  if (!token) {
    const r = await fetch("http://localhost:8787/auth/guest", { method: "POST" });
    const json = await r.json();
    token = json.token;
    localStorage.setItem("token", token);
  }
  return token;
}
const authReady = ensureToken();

async function refreshWallet() {
  const token = await authReady;
  try {
    const r = await fetch("http://localhost:8787/wallet", { headers: { Authorization: "Bearer " + token } });
    const json = await r.json();
    const log = document.getElementById("chat-log")!;
    const div = document.createElement("div");
    div.textContent = `[wallet] Acorns: ${json.acorns ?? 0}`;
    log.appendChild(div);
  } catch {}
}
// @ts-ignore
window.authReady = authReady;
(window as any).refreshWallet = refreshWallet;
refreshWallet();


socket.on('chat:message', (m: any) => {
  const log = document.getElementById('chat-log')!;
  const div = document.createElement('div');
  const ts = new Date(m.ts || Date.now()).toLocaleTimeString();
  div.textContent = `[${ts}] ${m.userId || 'anon'}: ${m.text}`;
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
});

const input = document.getElementById('chat-input') as HTMLInputElement;
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && input.value.trim()) {
    socket.emit('chat:send', { channel: 'global', text: input.value.trim(), userId: 'dev' });
    input.value = '';
  }
});

class HubScene extends Phaser.Scene {
  private player!: Phaser.GameObjects.Sprite;
  constructor() { super('Hub'); }
  preload() {
    if (!this.textures.exists('player')) {
      this.textures.generate('player', { data: ['2'], pixelWidth: 8, pixelHeight: 8 });
    }
  }
  create() {
    const w = this.scale.width, h = this.scale.height;
    this.player = this.add.sprite(w/2, h/2, 'player');
    this.add.text(10, 10, 'Plaza — flèches pour bouger. Utilise les boutons en haut.', { font: '16px sans-serif' });
    this.input.keyboard!.on('keydown', (event: KeyboardEvent) => {
      switch (event.key) {
        case 'ArrowUp': this.player.y -= 4; break;
        case 'ArrowDown': this.player.y += 4; break;
        case 'ArrowLeft': this.player.x -= 4; break;
        case 'ArrowRight': this.player.x += 4; break;
      }
    });
  }
}

const game = new Phaser.Game({
  type: Phaser.AUTO, parent: 'game', width: 960, height: 540, scene: [HubScene, FishingScene, MarketScene]
}) as Phaser.Game & { _current?: string };

// Buttons
document.getElementById('btn-fish')!.addEventListener('click', () => {
  const mgr = game.scene;
  mgr.stop('Hub');
  if (mgr.isActive('Fishing')) mgr.bringToTop('Fishing');
  else mgr.start('Fishing');
});

document.getElementById('btn-hub')!.addEventListener('click', () => {
  const mgr = game.scene;
  mgr.stop('Fishing');
  mgr.stop('Market');
  if (mgr.isActive('Hub')) mgr.bringToTop('Hub');
  else mgr.start('Hub');
});


// @ts-ignore
window.game = game;

// Market button (creates one if missing)
(() => {
  let btn = document.getElementById('btn-market');
  if (!btn) {
    const host = document.getElementById('controls') || document.body;
    btn = document.createElement('button');
    btn.id = 'btn-market';
    btn.textContent = 'Aller au marché';
    btn.style.margin = '4px';
    host.prepend(btn);
  }
  btn!.addEventListener('click', () => {
    // @ts-ignore
    const mgr = (window as any).game.scene;
    mgr.stop('Hub'); mgr.stop('Fishing');
    if (mgr.isActive('Market')) mgr.bringToTop('Market');
    else mgr.start('Market');
  });
})();

/* MARKET_WIRING */
(function wireMarketUI(){
  // Run after window.game exists
  const run = () => {
    // @ts-ignore
    const g = (window as any).game;
    if (!g || !g.scene) return false;

    // Ensure button exists
    let btn = document.getElementById('btn-market');
    if (!btn) {
      const host = document.getElementById('controls') || document.body;
      btn = document.createElement('button');
      btn.id = 'btn-market';
      btn.textContent = 'Aller au marché';
      (btn as HTMLButtonElement).style.margin = '4px';
      host.prepend(btn);
    }
    btn!.addEventListener('click', () => {
      const mgr = g.scene;
      mgr.stop('Hub'); mgr.stop('Fishing');
      if (mgr.isActive('Market')) mgr.bringToTop('Market');
      else mgr.start('Market');
    }, { once: false });

    // Keyboard shortcut: M -> Market, H -> Hub
    window.addEventListener('keydown', (e) => {
      if (e.key.toLowerCase() === 'm') {
        const mgr = g.scene;
        mgr.stop('Hub'); mgr.stop('Fishing');
        if (mgr.isActive('Market')) mgr.bringToTop('Market');
        else mgr.start('Market');
      }
      if (e.key.toLowerCase() === 'h') {
        const mgr = g.scene;
        mgr.stop('Fishing'); mgr.stop('Market');
        if (mgr.isActive('Hub')) mgr.bringToTop('Hub');
        else mgr.start('Hub');
      }
    });
    return true;
  };

  if (!run()) {
    // try again once Phaser has booted
    const iv = setInterval(() => { if (run()) clearInterval(iv); }, 200);
    setTimeout(() => clearInterval(iv), 8000);
  }
})();

/* MOVE_CONTROLS */
(function arrangeTopControls(){
  const run = () => {
    const host = document.getElementById('controls');
    if (!host) return false;
    const ids = ['btn-fish', 'btn-market', 'btn-hub'];
    for (const id of ids) {
      let el = document.getElementById(id);
      if (el && el.parentElement !== host) host.appendChild(el);
      if (el instanceof HTMLButtonElement) el.style.margin = '0';
    }
    return true;
  };
  if (!run()) {
    const iv = setInterval(() => { if (run()) clearInterval(iv); }, 200);
    setTimeout(() => clearInterval(iv), 6000);
  }
})();

/* MVP_LIMITS_HUD */
async function fetchLimits() {
  try {
    // @ts-ignore
    const token = await (window as any).authReady;
    const r = await fetch('http://localhost:8787/limits', { headers: { Authorization: 'Bearer ' + token } });
    const j = await r.json();
    const log = document.getElementById('chat-log')!;
    const div = document.createElement('div');
    div.textContent = `[limits] Cap restant aujourd'hui: ${j.remainingToday ?? 'N/A'}`;
    log.appendChild(div);
  } catch {}
}
// @ts-ignore
(window as any).refreshLimits = fetchLimits;
fetchLimits();

// Logout button (QoL)
(() => {
  let btn = document.getElementById('btn-logout');
  if (!btn) {
    const host = document.getElementById('controls') || document.body;
    btn = document.createElement('button');
    btn.id = 'btn-logout';
    btn.textContent = 'Déconnexion';
    (btn as HTMLButtonElement).style.margin = '4px';
    host.appendChild(btn);
  }
  btn!.addEventListener('click', () => {
    localStorage.removeItem('token');
    location.reload();
  });
})();
