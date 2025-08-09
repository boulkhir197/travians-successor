import Phaser from 'phaser';

export default class MarketScene extends Phaser.Scene {
  private info?: Phaser.GameObjects.Text;
  private result?: Phaser.GameObjects.Text;

  constructor() { super('Market'); }

  async create() {
    this.add.rectangle(0, 0, this.scale.width, this.scale.height, 0x1b222c).setOrigin(0);
    this.add.text(10, 10, 'Marché — vendez vos poissons', { font: '18px sans-serif' });

    this.info = this.add.text(10, 40, 'Chargement inventaire…', { font: '14px sans-serif' });

    try {
      // @ts-ignore
      const token = await (window as any).authReady;
      const invResp = await fetch('http://localhost:8787/inventory', { headers: { Authorization: 'Bearer ' + token } });
      const inv = await invResp.json();
      const fish = (inv.find((x: any) => x.item === 'fish')?.qty) || 0;
      this.info.setText(`Poissons: ${fish}`);

      this.add.text(10, 80, 'Vendre 1 poisson (+10 Acorns)', { font: '16px sans-serif', color: '#00ffaa' })
        .setInteractive({ useHandCursor: true })
        .on('pointerdown', async () => {
          try {
            const r = await fetch('http://localhost:8787/market/sell', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
              body: JSON.stringify({ item: 'fish', qty: 1 })
            });
            const json = await r.json();
            if (!r.ok) {
              this.result?.destroy();
              this.result = this.add.text(10, 110, 'Vente refusée', { font: '14px sans-serif', color: '#ff6666' });
              return;
            }
            this.result?.destroy();
            this.result = this.add.text(10, 110, `Vendu ! Acorns: ${json.acorns}`, { font: '14px sans-serif', color: '#aaddff' });
            this.info?.setText(`Poissons: ${json.item?.qty ?? 0}`);
            try {
              // @ts-ignore
              const refresh = (window as any).refreshWallet;
              if (typeof refresh === 'function') refresh();
            } catch {}
          } catch {
            this.result?.destroy();
            this.result = this.add.text(10, 110, 'Erreur réseau', { font: '14px sans-serif', color: '#ff6666' });
          }
        });
    } catch {
      this.info?.setText('Erreur inventaire');
    }
  }
}
