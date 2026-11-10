// Invented data for the smoke tests: one landlord company with two properties, one tenant on a
// lease, a few payments, expenses, repairs and messages. Dates are relative to today so pages that
// look at "this month" always have something to show. Never put real tenant data here.

const C = '11111111-1111-4111-8111-111111111111';
const P1 = '22222222-2222-4222-8222-222222222221';
const P2 = '22222222-2222-4222-8222-222222222222';
const L1 = '33333333-3333-4333-8333-333333333331';
const T1 = '44444444-4444-4444-8444-444444444441';
const LANDLORD = '55555555-5555-4555-8555-555555555551';
const TENANT = '55555555-5555-4555-8555-555555555552';

function iso(d) { return d.toISOString().slice(0, 10); }
function monthStart(offset) { const d = new Date(); return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + offset, 1)); }

function schedule() {
  const rows = [];
  for (let m = -3; m <= 1; m++) {
    const due = iso(monthStart(m));
    const paid = m < -1 ? 1500 : (m === -1 ? 500 : 0);
    rows.push({ property_id: P1, property_name: 'Oak Street', company_id: C, lease_id: L1, tenant_name: 'Test Tenant',
      lease_state: 'active', rent_amount: 1500, due_day: 1, grace_days: 5, lease_end: iso(monthStart(9)),
      charge_end: iso(new Date()), due_date: due, paid, balance: Math.max(1500 - paid, 0) });
  }
  return rows;
}

function base() {
  const today = iso(new Date());
  const sched = schedule();
  return {
    companies: [{ id: C, name: 'Smoke Test Rentals', owner_user_id: LANDLORD, payment_inbox_token: 'a1b2c3d4e5', payment_inbox_verify_url: null }],
    company_members: [{ company_id: C, user_id: LANDLORD, role: 'owner', companies: { id: C, name: 'Smoke Test Rentals' } }],
    properties: [
      { id: P1, name: 'Oak Street', address: '1 Oak Street, Springfield', company_id: C, owner_id: LANDLORD, status: 'occupied', occupancy_status: 'tenant_occupied',
        monthly_payment: 900, mortgage_pi: 700, archived_at: null, is_public_listing: false },
      { id: P2, name: 'Elm Avenue', address: '2 Elm Avenue, Springfield', company_id: C, owner_id: LANDLORD, status: 'vacant', occupancy_status: 'vacant',
        monthly_payment: 0, archived_at: null, is_public_listing: true, listing_application_mode: 'rental_genie' }
    ],
    leases: [{ id: L1, company_id: C, property_id: P1, property_name: 'Oak Street', tenant_id: T1, tenant_name: 'Test Tenant',
      tenant_email: 'tenant@example.com', tenant_phone: '555-0100', lease_start: iso(monthStart(-3)), lease_end: iso(monthStart(9)),
      rent_amount: 1500, rent_due_day: 1, due_day: 1, grace_period: 5, late_fee: 75, status: 'active', lease_type: 'fixed',
      archived_at: null, created_by: LANDLORD, tenant_preferred_payment_method: 'Zelle' }],
    tenants: [{ id: T1, auth_user_id: TENANT, tenant_name: 'Test Tenant', email: 'tenant@example.com', phone: '555-0100', property_name: 'Oak Street' }],
    rent_log: sched.filter(r => r.paid > 0).map((r, i) => ({ id: '66666666-6666-4666-8666-66666666666' + i, company_id: C,
      property_id: P1, property_name: 'Oak Street', lease_id: L1, tenant_id: T1, tenant_name: 'Test Tenant',
      tenant_email: 'tenant@example.com', amount: r.paid, method: 'Zelle', note: '', date_paid: r.due_date,
      applied_to_due_date: r.due_date, inserted_at: r.due_date + 'T12:00:00', archived_at: null })),
    expenses: [
      { id: 1, company_id: C, property_id: P1, property_name: 'Oak Street', category: 'Repairs & Maintenance', amount: 240, date_paid: today, vendor: 'Plumber', note: 'Leak', maintenance_request_id: 1, archived_at: null },
      { id: 2, company_id: C, property_id: P2, property_name: 'Elm Avenue', category: 'Insurance', amount: 90, date_paid: today, vendor: 'Insurer', note: '', archived_at: null }
    ],
    maintenance_requests: [{ id: 1, company_id: C, property_id: P1, property_name: 'Oak Street', tenant_id: T1, tenant_email: 'tenant@example.com',
      tenant_name: 'Test Tenant', issue_description: 'Kitchen tap drips', urgency_level: 'Normal', assigned_vendor: 'Ace Plumbing', status: 'Open',
      created_at: today + 'T09:00:00Z', archived_at: null }],
    tenant_messages: [{ id: 1, company_id: C, property_id: P1, property_name: 'Oak Street', tenant_id: T1, tenant_email: 'tenant@example.com',
      subject: 'Hello', message: 'Is the gutter work scheduled?', sender: 'tenant', created_at: today + 'T10:00:00Z', read_at: null }],
    tenant_documents: [],
    reimbursement_requests: [],
    applications: [],
    application_messages: [],
    incoming_rent_payments: [],
    vendors: [{ id: '77777777-7777-4777-8777-777777777771', company_id: C, name: 'Ace Plumbing', trade: 'Plumbing', phone: '555-0142', email: 'office@ace.example.com', archived_at: null }],
    notifications: [{ id: 1, company_id: C, event_key: 'maint_ack:1', kind: 'maintenance_ack', channel: 'email', maintenance_request_id: 1,
      property_id: P1, tenant_id: T1, recipient: 'tenant@example.com', status: 'failed', attempts: 1, dismissed_at: null,
      last_error: 'Resend 422: invalid to', created_at: today + 'T09:00:05Z' }],
    payment_settings: [{ company_id: C, zelle_handle: 'landlord@example.com' }],
    public_listings: [{ id: P2, name: 'Elm Avenue', address: '2 Elm Avenue, Springfield', listing_application_mode: 'rental_genie' }],
    rpc: {
      rg_rent_schedule: sched,
      rg_my_rent_schedule: sched,
      rg_rent_status: [{ property_id: P1, property_name: 'Oak Street', company_id: C, lease_id: L1, tenant_name: 'Test Tenant', lease_state: 'active',
        rent_amount: 1500, total_due: 4500, total_paid: 3500, balance: 1000, past_due: 1000, months_unpaid: 1, last_paid_date: sched[2].due_date }],
      rg_claim_tenant_row: T1,
      rg_dismiss_notification: true
    }
  };
}

module.exports = {
  landlord() { return Object.assign(base(), { user: { id: LANDLORD, email: 'landlord@example.com', email_confirmed_at: '2026-01-01T00:00:00Z', user_metadata: { full_name: 'Lana Landlord' } } }); },
  tenant() { return Object.assign(base(), { user: { id: TENANT, email: 'tenant@example.com', email_confirmed_at: '2026-01-01T00:00:00Z', user_metadata: {} } }); },
  guest() { return Object.assign(base(), { user: null }); }
};
