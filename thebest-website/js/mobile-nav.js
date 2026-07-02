const mobileNav = () => {
    const headerBtn = document.querySelector('.header__bars');
    const mobileNav = document.querySelector('.mobile-nav');
    const mobileLinks = document.querySelectorAll('.mobile-nav__link');

    let isMobileNavOpen = false;

    const openMenu = () => {
        mobileNav.style.display = 'flex';
        document.body.style.overflowY = 'hidden';
        document.documentElement.style.overflow = 'hidden';
        isMobileNavOpen = true;
    };

    const closeMenu = () => {
        mobileNav.style.display = 'none';
        document.body.style.overflowY = 'auto';
        document.documentElement.style.overflow = 'auto';
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
