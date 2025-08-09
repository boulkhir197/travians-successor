import Phaser from 'phaser';

export default class FishingScene extends Phaser.Scene {
  private cursor!: Phaser.GameObjects.Rectangle;
  private dir: number = 1;
  private speed: number = 2;

  constructor() { super('Fishing'); }

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

    this.input.keyboard?.on('keydown-SPACE', () => {
      if (this.cursor.y > 170 && this.cursor.y < 230) {
        this.add.text(100, 400, 'Poisson attrapé ! (+10 Acorns)', { font: '20px sans-serif', color: '#00ff88' });
      } else {
        this.add.text(100, 430, 'Raté…', { font: '20px sans-serif', color: '#ff6666' });
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
