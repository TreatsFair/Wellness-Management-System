const mobileNav = () => {
    const headerBtn = document.querySelector('.header__bars');
    const mobileNav = document.querySelector('.mobile-nav');
    const mobileLinks = document.querySelectorAll('.mobile-nav__link');

    let isMobileNavOpen = false;

    // Only touch overflow-y; forcing overflow(-x) to auto here would undo
    // the horizontal clipping the stylesheet applies to html/body.
    const openMenu = () => {
        mobileNav.style.display = 'flex';
        document.body.style.overflowY = 'hidden';
        document.documentElement.style.overflowY = 'hidden';
        isMobileNavOpen = true;
    };

    const closeMenu = () => {
        mobileNav.style.display = 'none';
        document.body.style.overflowY = '';
        document.documentElement.style.overflowY = '';
        isMobileNavOpen = false;
    };

    headerBtn.addEventListener('click', () => {
        isMobileNavOpen ? closeMenu() : openMenu();
    });

    mobileLinks.forEach(link => {
        link.addEventListener('click', closeMenu);
    });
};

mobileNav();
