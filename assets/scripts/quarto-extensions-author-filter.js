// Enhanced author filter functionality for Quarto Extensions Listing
// This script enables filtering extensions by author using the login value

(function() {
  document.addEventListener('DOMContentLoaded', function() {
    // ...existing code...

    // Add event delegation for author filter buttons
    document.body.addEventListener('click', function(event) {
      const target = event.target.closest('.filter-chip[data-filter="author"][data-login]');
      if (!target) return;
      const login = target.getAttribute('data-login');
      if (!login) return;

      // Remove active state from all author filter buttons
      document.querySelectorAll('.filter-chip[data-filter="author"][data-login]').forEach(btn => {
        btn.classList.remove('active');
      });
      target.classList.add('active');

      // Hide all extensions except those matching the selected login
      document.querySelectorAll('.extension-item, .extension-card').forEach(ext => {
        const extLogin = ext.getAttribute('data-login');
        ext.closest('.list-group-item, .col-sm-6, .col-lg-4').style.display = (extLogin === login) ? '' : 'none';
      });
    });

    // ...existing code...
  });
})();
