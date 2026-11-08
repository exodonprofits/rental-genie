/* Navigation only: access checks and data scope remain with each page and RLS. */
(function(){
  var main=document.querySelector('main');if(!main)return;
  var nav=document.createElement('nav');nav.className='tenant-resource-nav';nav.setAttribute('aria-label','Your rental');
  var current=location.pathname.split('/').pop(),property=new URLSearchParams(location.search).get('property');
  [['Home','tenant-portal.html'],['Payments','tenant-payments.html'],['Documents','tenant-documents.html'],['Messages','tenant-contact.html'],['Repairs','tenant-repair-requests.html']].forEach(function(pair){var link=document.createElement('a'),url=new URL(pair[1],location.origin);if(property)url.searchParams.set('property',property);link.href=url.pathname+url.search;link.textContent=pair[0];if(current===pair[1])link.setAttribute('aria-current','page');nav.appendChild(link)});
  main.insertBefore(nav,main.firstChild);
}());
