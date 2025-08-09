import Phaser from 'phaser';
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
  type: Phaser.AUTO, parent: 'game', width: 960, height: 540, scene: [HubScene, FishingScene]
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
  if (mgr.isActive('Hub')) mgr.bringToTop('Hub');
  else mgr.start('Hub');
});


// @ts-ignore
window.game = game;
