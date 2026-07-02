const menuImages = document.querySelectorAll('.menu__img');

menuImages.forEach(image => {
    image.addEventListener('click', () => {
        const imageUrl = image.src; // Get the image source URL
        window.open(imageUrl, '_blank'); // Open the image in a new tab or window
    });
});
