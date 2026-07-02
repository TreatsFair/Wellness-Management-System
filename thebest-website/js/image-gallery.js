document.addEventListener('DOMContentLoaded', () => {
    // Select the grid container
    const gallery = document.querySelector('.pics__grid');
    
    // Select all images inside the grid
    const images = Array.from(gallery.querySelectorAll('img'));
    
    // Select the new toggle buttons
    const buttons = document.querySelectorAll('.toggle-btn');

    const allImageSources = [
        // Set 0: Kepong Images
        [
            "./pics/thebestwellness_outside.jpg",
            "./pics/thebestwellness_front.jpg",
            "./pics/thebestwellness_counter.jpg",
            "./pics/thebestwellness_massagearea.jpg",
            "./pics/thebestwellness_massaging.jpg",
            "./pics/thhebestwellness_foot.jpg"
        ],
        // Set 1: Setapak Images
        [
            "./pics/thebest_setapak_outside.jpg", 
            "./pics/thebest_setapak_outside2.jpg", 
            "./pics/thebest_setapak_upstair.webp", 
            "./pics/thebest_setapak_counter.png", 
            "./pics/thebest_setapak_inside.jpg", 
            "./pics/thebest_setapak_chair.webp" 
        ]
    ];

    // Function to switch location
    function switchLocation(index) {
        // 1. Update Buttons: Remove 'active' from all, add to clicked
        buttons.forEach(btn => btn.classList.remove('active'));
        buttons[index].classList.add('active');

        // 2. Update Images
        const currentSet = allImageSources[index];
        images.forEach((img, i) => {
            // Add a fade effect
            img.style.opacity = '0';
            
            setTimeout(() => {
                if (currentSet[i]) {
                    img.src = currentSet[i];
                    img.alt = `Outlet view ${index == 0 ? 'Kepong' : 'Setapak'} ${i + 1}`;
                }
                img.style.opacity = '1';
            }, 200); // Short delay for fade
        });
    }

    // Add click event to buttons
    buttons.forEach(btn => {
        btn.addEventListener('click', () => {
            // Get the index from the HTML data-index attribute (0 or 1)
            const index = parseInt(btn.getAttribute('data-index'));
            switchLocation(index);
        });
    });
});
