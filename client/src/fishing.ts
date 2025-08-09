import Phaser from 'phaser';

export default class FishingScene extends Phaser.Scene {
  private cursor!: Phaser.GameObjects.Rectangle;
  private dir: number = 1;
  private speed: number = 2;
  private statusOk?: Phaser.GameObjects.Text;
  private statusFail?: Phaser.GameObjects.Text;
  private acornsText?: Phaser.GameObjects.Text;

  constructor() { super('Fishing'); }

  /* MVP_SOUNDS */
  preload() {
    if (!this.sound.get('catch')) this.load.audio('catch','/sfx/catch.wav');
    if (!this.sound.get('miss')) this.load.audio('miss','/sfx/miss.wav');
  }

  create() {
    // Fond gris pour vérifier que la scène est bien devant
    this.add.rectangle(0, 0, this.scale.width, this.scale.height, 0x202830).setOrigin(0);

    this.add.text(10, 10, 'PÊCHE — Appuyez sur ESPACE quand la barre est au milieu', { font: '16px sans-serif' });

    // Jauge (grise)
    this.add.rectangle(200, 200, 30, 200, 0x999999);

    // Zone "verte" de réussite (semi-transparente)
    this.add.rectangle(200, 200, 30, 60, 0x00ff00).setAlpha(0.35);

    // Curseur rouge
    this.cursor = this.add.rectangle(200, 170, 30, 10, 0xff4444);

    // Debug: texte pour afficher la position du curseur
    const debug = this.add.text(10, 36, '', { font: '12px monospace' });

    this.input.keyboard?.on('keydown-SPACE', async () => {
      const success = this.cursor.y > 170 && this.cursor.y < 230;

      const put = (ref: Phaser.GameObjects.Text | undefined, x: number, y: number, txt: string, color: string) => {
        if (!ref) {
          ref = this.add.text(x, y, txt, { font: '20px sans-serif', color });
          ref.setDepth(1000);
        } else {
          ref.setText(txt).setColor(color).setAlpha(1);
        }
        return ref;
      };

      if (success) {
        this.statusFail?.setAlpha(0);
        this.statusOk = put(this.statusOk, 100, 400, 'Poisson attrapé ! (+10 Acorns)', '#00ff88'); this.sound.play('catch',{volume:0.6});

        try {
          // @ts-ignore
          const token = await (window as any).authReady;
          const r = await fetch('http://localhost:8787/jobs/fishing/catch', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
            body: JSON.stringify({ success: true })
          });

          if (!r.ok) {
            let msg = 'Récompense refusée';
            try {
              const err = await r.json();
              if (err?.error === 'cooldown') {
                const secs = Math.ceil((err.retryInMs || 0) / 1000);
                msg = `Cooldown… réessayez dans ${secs}s`;
              }
            } catch {}
            this.acornsText = put(this.acornsText, 100, 460, msg, '#ffaa00');
            return;
          }

          const json = await r.json();
          this.acornsText = put(this.acornsText, 100, 460, `Acorns: `, '#aaddff');
          if (json.capped || (json.remainingToday!==undefined && json.remainingToday<=0)) {
            this.add.text(100, 485, "Cap atteint pour aujourd'hui", { font: '14px sans-serif', color: '#ffaa00' });
          }
          try { const rf = (window as any).refreshLimits; if (typeof rf==='function') rf(); } catch {}

          // rafraîchir le HUD du chat
          try {
            // @ts-ignore
            const refresh = (window as any).refreshWallet;
            if (typeof refresh === 'function') refresh();
          } catch {}
        } catch {
          this.acornsText = put(this.acornsText, 100, 460, 'Erreur récompense', '#ff6666');
        }
      } else {
        this.statusOk?.setAlpha(0);
        this.statusFail = put(this.statusFail, 100, 430, 'Raté…', '#ff6666'); this.sound.play('miss',{volume:0.5});
      }
    });

    // Assure que la scène est au-dessus du Hub
    this.scene.bringToTop();
    debug.setText('Fishing active (on top)');
  }

  update() {
    this.cursor.y += this.speed * this.dir;
    if (this.cursor.y > 280 || this.cursor.y < 120) this.dir *= -1;
  }
}
