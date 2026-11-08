/* Tenant navigation only: access checks and data scope remain with each page and RLS.
   - Desktop: a tab card at the top of <main> on the redesigned pages (body.tenant-workspace).
   - Phone (<= 880px, where the header shows the hamburger): the tab card is replaced by a fixed
     bottom tab bar, like the landlord dashboard's, and the hamburger drawer becomes a two-column
     grid that marks the current page.
   Every link carries ?property= so the tenant stays on the same rental. */
(function(){
  var main=document.querySelector('main');if(!main)return;
  var current=location.pathname.split('/').pop()||'tenant-portal.html';
  var property=new URLSearchParams(location.search).get('property');
  function withProp(href){var url=new URL(href,location.href);if(property)url.searchParams.set('property',property);return url.pathname.split('/').pop()+url.search;}
  var TABS=[
    ['Home','tenant-portal.html','🏠'],
    ['Payments','tenant-payments.html','💵'],
    ['Repairs','tenant-repair-requests.html','🛠️'],
    ['Documents','tenant-documents.html','📁'],
    ['Messages','tenant-contact.html','💬']
  ];

  // Desktop tab card, on the redesigned workspace pages only (elsewhere the header links cover it)
  if(document.body.classList.contains('tenant-workspace')){
    var nav=document.createElement('nav');nav.className='tenant-resource-nav';nav.setAttribute('aria-label','Your rental');
    TABS.forEach(function(t){var a=document.createElement('a');a.href=withProp(t[1]);a.textContent=t[0];if(current===t[1])a.setAttribute('aria-current','page');nav.appendChild(a);});
    main.insertBefore(nav,main.firstChild);
  }

  // Phone bottom tab bar
  var bar=document.createElement('nav');bar.className='tenant-tabbar';bar.setAttribute('aria-label','Your rental');
  var inner=document.createElement('div');inner.className='tenant-tabbar-inner';
  TABS.forEach(function(t){
    var a=document.createElement('a');a.className='tenant-tab';a.href=withProp(t[1]);
    var ico=document.createElement('span');ico.className='tenant-tab-ico';ico.setAttribute('aria-hidden','true');ico.textContent=t[2];
    var label=document.createElement('span');label.className='tenant-tab-label';label.textContent=t[0]==='Documents'?'Docs':t[0];
    a.appendChild(ico);a.appendChild(label);
    if(current===t[1])a.setAttribute('aria-current','page');
    inner.appendChild(a);
  });
  bar.appendChild(inner);document.body.appendChild(bar);document.body.classList.add('has-tenant-tabbar');

  // Hamburger drawer: two-column grid, current page marked, property carried
  var drawer=document.getElementById('mobileDrawer');
  if(drawer&&!drawer.querySelector('.drawer-grid')){
    var grid=document.createElement('div');grid.className='drawer-grid';
    Array.prototype.slice.call(drawer.children).forEach(function(el){
      if(el.tagName!=='A'||el.classList.contains('drawer-signout')||el.getAttribute('href')==='#')return;
      var target=(el.getAttribute('href')||'').split('?')[0];
      el.classList.remove('nav-active');el.removeAttribute('aria-current');
      if(target===current){el.classList.add('nav-active');el.setAttribute('aria-current','page');}
      el.setAttribute('href',withProp(el.getAttribute('href')));
      grid.appendChild(el);
    });
    drawer.insertBefore(grid,drawer.firstChild);
  }
}());
