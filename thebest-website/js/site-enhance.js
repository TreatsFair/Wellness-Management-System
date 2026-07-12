// Scroll reveal + services carousel controls.
// The js-reveal class gates the hidden initial state so content stays
// visible if this script never runs.
document.documentElement.classList.add('js-reveal');

document.addEventListener('DOMContentLoaded', () => {
    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    /* ---------- Scroll reveal ---------- */
    const revealEls = document.querySelectorAll('.reveal');

    if (reduceMotion || !('IntersectionObserver' in window)) {
        revealEls.forEach(el => el.classList.add('is-visible'));
    } else {
        const observer = new IntersectionObserver(entries => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('is-visible');
                    observer.unobserve(entry.target);
                }
            });
        }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });

        revealEls.forEach(el => observer.observe(el));
    }

    /* ---------- Gallery view-more (phones) ---------- */
    const galleryGrid = document.querySelector('.pics__grid');
    const galleryMore = document.getElementById('gallery-more');

    if (galleryGrid && galleryMore) {
        galleryMore.addEventListener('click', () => {
            const collapsed = galleryGrid.classList.toggle('is-collapsed');
            galleryMore.textContent = collapsed ? 'View more photos' : 'View fewer photos';
            galleryMore.setAttribute('aria-expanded', String(!collapsed));
            if (collapsed) {
                galleryGrid.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
            }
        });
    }

    /* ---------- Services carousel ---------- */
    const carousel = document.querySelector('[data-carousel]');
    if (!carousel) return;

    const track = carousel.querySelector('[data-carousel-track]');
    const nav = carousel.querySelector('.carousel-nav');
    const prevBtn = carousel.querySelector('[data-carousel-prev]');
    const nextBtn = carousel.querySelector('[data-carousel-next]');
    if (!track || !nav || !prevBtn || !nextBtn) return;

    function cardStep() {
        const card = track.querySelector('.home-service-card');
        if (!card) return track.clientWidth;
        const gap = parseFloat(getComputedStyle(track).columnGap) || 0;
        return card.getBoundingClientRect().width + gap;
    }

    function updateNav() {
        const overflow = track.scrollWidth - track.clientWidth;
        nav.hidden = overflow < 8;
        prevBtn.disabled = track.scrollLeft <= 4;
        nextBtn.disabled = track.scrollLeft >= overflow - 4;
    }

    // pendingTarget accumulates rapid clicks so each press advances one
    // card even while the previous smooth scroll is still animating.
    let pendingTarget = null;

    function scrollToCard(direction) {
        const step = cardStep();
        const maxLeft = track.scrollWidth - track.clientWidth;
        const base = pendingTarget !== null
            ? pendingTarget
            : Math.round(track.scrollLeft / step) * step;
        pendingTarget = Math.min(Math.max(base + direction * step, 0), maxLeft);
        track.scrollTo({ left: pendingTarget, behavior: reduceMotion ? 'auto' : 'smooth' });
    }

    prevBtn.addEventListener('click', () => scrollToCard(-1));
    nextBtn.addEventListener('click', () => scrollToCard(1));
    track.addEventListener('scrollend', () => { pendingTarget = null; });
    track.addEventListener('pointerdown', () => { pendingTarget = null; });

    track.addEventListener('scroll', updateNav, { passive: true });
    window.addEventListener('resize', updateNav);
    updateNav();
});
