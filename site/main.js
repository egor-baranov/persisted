(() => {
  'use strict';
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const faqControllers = new Map();

  document.querySelectorAll('.question-list details').forEach(details => {
    const summary = details.querySelector('summary');
    const answer = details.querySelector('.faq-answer');
    if (!summary || !answer) return;
    let expanded = details.open;
    let animation = null;
    details.dataset.expanded = String(expanded);

    const setExpanded = (next, { animate = true } = {}) => {
      if (expanded === next && (!animation || animate && !reducedMotion.matches)) return;
      const height = details.open ? answer.getBoundingClientRect().height : 0;
      animation?.cancel();
      animation = null;
      expanded = next;
      details.dataset.expanded = String(next);
      summary.setAttribute('aria-expanded', String(next));
      const finish = () => {
        details.open = next;
        animation?.cancel();
        animation = null;
        answer.style.removeProperty('overflow');
        answer.inert = false;
      };
      if (!animate || reducedMotion.matches || !answer.animate) {
        finish();
        return;
      }
      // Keep native details open while the answer collapses, then close it.
      details.open = true;
      const targetHeight = next ? answer.getBoundingClientRect().height : 0;
      answer.style.overflow = 'hidden';
      answer.inert = !next;
      const current = answer.animate(
        [{ height: `${height}px` }, { height: `${targetHeight}px` }],
        { duration: 280, easing: 'cubic-bezier(.22, 1, .36, 1)', fill: 'both' }
      );
      animation = current;
      current.onfinish = () => {
        if (animation === current) finish();
      };
    };
    faqControllers.set(details, setExpanded);
    summary.addEventListener('click', event => {
      event.preventDefault();
      setExpanded(!expanded);
    });
    details.addEventListener('toggle', () => {
      if (animation) return;
      expanded = details.open;
      details.dataset.expanded = String(expanded);
      summary.setAttribute('aria-expanded', String(expanded));
    });
  });

  const setFAQExpanded = (details, options) => {
    const setExpanded = faqControllers.get(details);
    if (setExpanded) setExpanded(true, options);
    else details.open = true;
  };
  reducedMotion.addEventListener('change', () => {
    if (reducedMotion.matches) faqControllers.forEach((setExpanded, details) => {
      setExpanded(details.dataset.expanded === 'true', { animate: false });
    });
  });
  const revealLinkedFAQ = ({ animate = true } = {}) => {
    let id;
    try { id = decodeURIComponent(location.hash.slice(1)); } catch { return; }
    const target = document.getElementById(id);
    const details = target?.closest('details');
    if (!details) return;
    setFAQExpanded(details, { animate });
    target.scrollIntoView({ block: 'start' });
  };
  revealLinkedFAQ({ animate: false });
  window.addEventListener('hashchange', revealLinkedFAQ);

  const viewer = document.getElementById('image-viewer');
  const image = document.getElementById('viewer-image');
  const title = document.getElementById('image-title');
  const close = document.getElementById('close-viewer');
  let trigger = null;

  document.querySelectorAll('[data-image]').forEach(button => {
    button.addEventListener('click', () => {
      trigger = button;
      image.src = button.dataset.image;
      image.alt = button.querySelector('img').alt;
      title.textContent = button.dataset.title;
      viewer.showModal();
      viewer.querySelector('[data-viewer-scroll]').scrollTop = 0;
      close.focus();
    });
  });
  close.addEventListener('click', () => viewer.close());
  viewer.addEventListener('click', event => {
    if (event.target !== viewer) return;
    const rect = viewer.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) viewer.close();
  });
  // Native dialog Escape handling also triggers close and returns focus.
  viewer.addEventListener('close', () => {
    if (trigger) trigger.focus({ preventScroll: true });
  });

  document.querySelectorAll('[data-open-details]').forEach(link => {
    link.addEventListener('click', () => {
      const details = document.getElementById(link.dataset.openDetails);
      if (details) setFAQExpanded(details);
    });
  });

  document.querySelectorAll('[data-copy]').forEach(button => {
    button.addEventListener('click', async () => {
      const status = document.getElementById('copy-status');
      try {
        if (!navigator.clipboard) throw new Error('Clipboard unavailable');
        await navigator.clipboard.writeText(button.dataset.copy);
        status.textContent = 'Build command copied.';
        button.textContent = 'Copied';
      } catch {
        const range = document.createRange();
        range.selectNodeContents(button.previousElementSibling);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        status.textContent = 'Command selected. Press Command-C (Mac) or Ctrl-C to copy.';
      }
    });
  });
})();
