/* Non-blocking section navigation and review. Existing validation and saves own persistence. */
(function () {
  'use strict';
  var kind = document.body.dataset.entryGuide;
  if (!kind) return;
  var main = document.querySelector('main');
  var save = document.getElementById(kind === 'property' ? 'savePropertyBtn' : 'saveLeaseBtn');
  if (!main || !save) return;
  var sections = Array.from(main.querySelectorAll('.section-card'));
  var nav = document.createElement('nav');
  nav.className = 'entry-guide-nav';
  nav.setAttribute('aria-label', 'Form sections');
  var intro = document.createElement('p');
  intro.className = 'entry-guide-intro';
  intro.textContent = 'Work through the sections in any order. Review the details before saving. Unsaved changes stay on this page only.';
  var review = document.createElement('section');
  review.id = 'entryReview'; review.className = 'section-card entry-review'; review.tabIndex = -1;
  review.setAttribute('aria-labelledby', 'entryReviewTitle');
  var title = document.createElement('h2'); title.id = 'entryReviewTitle'; title.textContent = 'Review before saving';
  var hint = document.createElement('p'); hint.textContent = 'This is a summary of key fields, not a complete review of the record. Check all sections before saving.';
  var summary = document.createElement('dl'); summary.className = 'entry-review-summary';
  review.append(title, hint, summary);
  function link(label, target) {
    var a = document.createElement('a'); a.textContent = label; a.href = '#' + target.id;
    a.addEventListener('click', function (event) {
      event.preventDefault(); renderReview();
      target.scrollIntoView({block:'start', behavior:matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth'});
      target.focus({preventScroll:true});
    }); nav.appendChild(a);
  }
  sections.forEach(function (section, index) {
    section.id = section.id || 'entrySection' + (index + 1); section.tabIndex = -1;
    var heading = section.querySelector('.section-title');
    if (heading) { heading.setAttribute('role','heading'); heading.setAttribute('aria-level','2'); }
    link((index + 1) + '. ' + (heading ? heading.textContent.trim() : 'Details'), section);
  });
  var advanced = document.getElementById('advToggleBar');
  if(advanced) {
    link('Financial details (optional)', advanced);
    nav.lastElementChild.addEventListener('click', function() {
      if(advanced.getAttribute('aria-expanded') !== 'true') advanced.click();
    });
  }
  link('Review', review);
  var status = document.getElementById('statusMsg');
  var first = status || sections[0];
  first.parentNode.insertBefore(intro, first); first.parentNode.insertBefore(nav, first);
  save.parentNode.parentNode.insertBefore(review, save.parentNode);
  var fields = kind === 'property' ? [
    ['Property','propertyName'], ['Address','propertyAddress'], ['Property use','useType'], ['Occupancy','propertyStatus'], ['Purchase price','purchasePrice']
  ] : [
    ['Tenant','tenantName'], ['Email','tenantEmail'], ['Lease type','leaseType'], ['Status','status'], ['Start','leaseStart'], ['End','leaseEnd'], ['Monthly rent','rentAmount'], ['Due day','dueDay'], ['Security deposit','securityDeposit']
  ];
  function renderReview() {
    summary.replaceChildren();
    fields.forEach(function (pair) {
      var control = document.getElementById(pair[1]);
      if (!control) return;
      var group = document.createElement('div'), label = document.createElement('dt'), value = document.createElement('dd');
      label.textContent = pair[0];
      var raw = control.value;
      value.textContent = raw ? (control.tagName === 'SELECT' ? control.selectedOptions[0].textContent : raw) : 'Not entered';
      group.append(label,value); summary.appendChild(group);
    });
  }
  main.addEventListener('input', renderReview); main.addEventListener('change', renderReview);
  review.addEventListener('focus', renderReview); renderReview();
  // Hydration uses programmatic assignments; refresh the summary on review/navigation/focus.
  window.addEventListener('focus', renderReview);
}());
