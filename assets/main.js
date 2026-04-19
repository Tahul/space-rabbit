// Theme toggle
const btn = document.getElementById('theme-toggle');
const moon = document.getElementById('icon-moon');
const sun = document.getElementById('icon-sun');

function setMode(light) {
  document.body.classList.toggle('light', light);
  moon.style.display = light ? 'none' : 'block';
  sun.style.display  = light ? 'block' : 'none';
  localStorage.setItem('theme', light ? 'light' : 'dark');
}

// Default: dark. Restore saved preference if any.
setMode(localStorage.getItem('theme') === 'light');

btn.addEventListener('click', () => setMode(!document.body.classList.contains('light')));

// Starfield
(function () {
  if (window.matchMedia('(max-width: 768px)').matches) return;

  const canvas = document.getElementById('stars');
  const ctx = canvas.getContext('2d');
  const COUNT = 180;
  let stars = [];
  let W, H, CX, CY;

  function resize() {
    W = canvas.width  = window.innerWidth;
    H = canvas.height = window.innerHeight;
    CX = W / 2;
    CY = H / 2;
  }

  function randomStar() {
    const angle = Math.random() * Math.PI * 2;
    const dist  = Math.random() * 0.3;
    return {
      angle,
      dist,
      speed: Math.random() * 0.00006 + 0.00002,
      streaker: Math.random() < 0.4, // 40% of stars can become streaks
    };
  }

  function init() {
    resize();
    stars = Array.from({ length: COUNT }, () => {
      const s = randomStar();
      s.dist = Math.random(); // scatter initial positions across full field
      return s;
    });
  }

  let rafId;
  let throttle = 1;       // 1 = full speed, 0 = stopped
  let targetThrottle = 1;
  let warp = 0;           // 0 = normal, 1 = warp hover
  let targetWarp = 0;

  function draw() {
    const isLight  = document.body.classList.contains('light');
    const isFocused = document.hasFocus() && !document.hidden;
    const effective = (isLight || !isFocused) ? 0 : targetThrottle;
    throttle += (effective - throttle) * 0.04;
    warp += ((isFocused && !isLight ? targetWarp : 0) - warp) * 0.05;

    ctx.clearRect(0, 0, W, H);
    const maxR = Math.hypot(CX, CY);

    for (const s of stars) {
      s.dist += (s.speed + s.dist * 0.003) * throttle;
      const d = s.dist * maxR;
      const x = CX + Math.cos(s.angle) * d;
      const y = CY + Math.sin(s.angle) * d;
      const progress = Math.min(s.dist, 1);
      const baseOpacity = Math.min(progress * 1.4, 0.45);
      const opacity = baseOpacity + warp * 0.4;

      if (warp > 0.01 && s.streaker) {
        const streakLen = warp * 0.06;
        const d0 = Math.max(0, s.dist - streakLen) * maxR;
        const x0 = CX + Math.cos(s.angle) * d0;
        const y0 = CY + Math.sin(s.angle) * d0;
        const grad = ctx.createLinearGradient(x0, y0, x, y);
        grad.addColorStop(0, `rgba(200,200,255,0)`);
        grad.addColorStop(1, `rgba(200,200,255,${opacity * 0.35})`);
        ctx.beginPath();
        ctx.moveTo(x0, y0);
        ctx.lineTo(x, y);
        ctx.strokeStyle = grad;
        ctx.lineWidth = progress * 0.8 + 0.1;
        ctx.stroke();
      }

      // Always draw the dot (streakers get a slightly dimmer dot)
      const dotOpacity = (warp > 0.01 && s.streaker) ? opacity * 0.6 : opacity;
      ctx.beginPath();
      ctx.arc(x, y, progress * 2.2 + 0.4, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(200,200,255,${dotOpacity})`;
      ctx.fill();

      if (s.dist > 1) Object.assign(s, randomStar());
    }
    rafId = requestAnimationFrame(draw);
  }

  const dlBtn = document.querySelector('.btn-download');
  dlBtn.addEventListener('mouseenter', () => { targetThrottle = 12; targetWarp = 1; });
  dlBtn.addEventListener('mouseleave', () => { targetThrottle = 1;  targetWarp = 0; });
  dlBtn.addEventListener('mousedown',  () => { targetThrottle = 0;  targetWarp = 0; });
  dlBtn.addEventListener('mouseup',    () => { targetThrottle = 12; targetWarp = 1; });

  window.addEventListener('resize', resize);
  init();
  draw();
})();

// Scroll hint button
const scrollHint = document.getElementById('scroll-hint');
scrollHint.addEventListener('click', () => {
  document.getElementById('comparison').scrollIntoView({ behavior: 'smooth' });
});
window.addEventListener('scroll', () => {
  scrollHint.classList.toggle('hidden', window.scrollY > window.innerHeight * 0.3);
}, { passive: true });

// Randomize footer author order
const authorsEl = document.querySelector('.footer-authors');
const authors = [...authorsEl.children];
for (let i = authors.length - 1; i > 0; i--) {
  const j = Math.floor(Math.random() * (i + 1));
  authorsEl.appendChild(authors[j]);
  [authors[i], authors[j]] = [authors[j], authors[i]];
}

// Comparison animation loop
(function() {
  const SWITCH_DURATION = 800;   // ms — macOS slide animation duration
  const HOLD = 1800;             // ms — pause after switch before resetting
  const PAUSE = 1200;            // ms — pause at start of each cycle

  const beforeA = document.querySelector('#mock-before .space-a');
  const beforeB = document.querySelector('#mock-before .space-b');
  const afterA  = document.querySelector('#mock-after  .space-a');
  const afterB  = document.querySelector('#mock-after  .space-b');
  const timerBefore = document.getElementById('timer-before');
  const timerAfter  = document.getElementById('timer-after');
  const keyBeforeCtrl = document.getElementById('key-before-ctrl');
  const keyBeforeArrow = document.getElementById('key-before-arrow');
  const keyAfterCtrl = document.getElementById('key-after-ctrl');
  const keyAfterArrow = document.getElementById('key-after-arrow');

  let toRight = true;  // direction alternates each cycle

  function formatTime(ms) { return (ms / 1000).toFixed(1) + 's'; }

  function runCycle() {
    const arrowDir = toRight ? '→' : '←';

    // Update arrow directions and show key buttons
    keyBeforeArrow.textContent = arrowDir;
    keyAfterArrow.textContent = arrowDir;
    keyBeforeCtrl.classList.add('show');
    keyBeforeArrow.classList.add('show');
    keyAfterCtrl.classList.add('show');
    keyAfterArrow.classList.add('show');

    // Set initial positions (no transition)
    beforeA.style.transition = 'none';
    beforeB.style.transition = 'none';
    if (toRight) {
      beforeA.style.transform = 'translateX(0)';      // Desktop 1 visible
      beforeB.style.transform = 'translateX(100%)';   // Desktop 2 off-screen right
    } else {
      beforeB.style.transform = 'translateX(0)';      // Desktop 2 visible
      beforeA.style.transform = 'translateX(-100%)';  // Desktop 1 off-screen left
    }

    // Tick before timer
    let elapsed = 0;
    const tick = setInterval(() => {
      elapsed += 50;
      timerBefore.textContent = formatTime(Math.min(elapsed, SWITCH_DURATION));
      if (elapsed >= SWITCH_DURATION) clearInterval(tick);
    }, 50);

    // Trigger slide animation
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        beforeA.style.transition = `transform ${SWITCH_DURATION}ms cubic-bezier(0.4,0,0.2,1)`;
        beforeB.style.transition = `transform ${SWITCH_DURATION}ms cubic-bezier(0.4,0,0.2,1)`;
        if (toRight) {
          beforeA.style.transform = 'translateX(-100%)';  // Desktop 1 slides out left
          beforeB.style.transform = 'translateX(0)';      // Desktop 2 slides in from right
        } else {
          beforeB.style.transform = 'translateX(100%)';   // Desktop 2 slides out right
          beforeA.style.transform = 'translateX(0)';      // Desktop 1 slides in from left
        }
      });
    });

    // After panel: instant cut, timer stays 0.0s
    timerAfter.textContent = '0.0s';
    afterA.style.transition = 'none';
    afterB.style.transition = 'none';
    if (toRight) {
      afterA.style.transform = 'translateX(-100%)';
      afterB.style.transform = 'translateX(0)';
    } else {
      afterB.style.transform = 'translateX(100%)';
      afterA.style.transform = 'translateX(0)';
    }

    setTimeout(() => {
      // Hide key buttons
      keyBeforeCtrl.classList.remove('show');
      keyBeforeArrow.classList.remove('show');
      keyAfterCtrl.classList.remove('show');
      keyAfterArrow.classList.remove('show');

      toRight = !toRight;
      timerBefore.textContent = '0.0s';

      setTimeout(runCycle, PAUSE);
    }, SWITCH_DURATION + HOLD);
  }

  setTimeout(runCycle, PAUSE);
})();
