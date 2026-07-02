const serviceCardImages = document.querySelectorAll('.home-service-card .menu__img');


serviceCardImages.forEach(image => {
    const newImage = image.cloneNode(true);
    image.parentNode.replaceChild(newImage, image);
});
