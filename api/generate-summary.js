export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return res.status(500).json({ error: 'API key not configured' });
  }

  try {
    const { household } = req.body;
    if (!household) {
      return res.status(400).json({ error: 'No household data provided' });
    }

    const h = household;
    const totalIncome = (h.monthly_income || 0) + (h.ssi_ssdi_amount || 0);
    const docsCount = (h.documents || []).length;
    const flags = (h.readiness_flags || []).join(', ') || 'None';

    const prompt = `Write a clear, professional 3-4 sentence summary of this NYC housing voucher applicant for a landlord to review. Be factual and concise. Highlight strengths. If there are readiness flags, mention them briefly. Do NOT use bullet points — write in paragraph form.

Applicant: ${h.head_of_household || 'Unknown'}
Program: ${h.voucher_program || 'Unknown'}
Voucher Status: ${h.voucher_status || 'Unknown'}
Bedroom Size: ${h.authorized_bedrooms || 'Unknown'}
Household Members: ${h.household_members || 1}
Employment: ${h.employment_status || 'Unknown'}
Monthly Income: $${h.monthly_income || 0}
SSI/SSDI: $${h.ssi_ssdi_amount || 0}
Total Income: $${totalIncome}
Tenant Contribution: $${h.tenant_contribution || 0}
Max Rent: $${h.max_rent || 0}
Payment Standard: $${h.voucher_payment_standard || 0}
Documents Verified: ${docsCount}/7
Move-in Timeline: ${h.move_in_timeline || 'Flexible'}
Preferred Neighborhoods: ${(h.preferred_neighborhoods || []).join(', ') || 'None specified'}
Elevator Required: ${h.elevator_required ? 'Yes' : 'No'}
Pets: ${h.pets || 'None'}
Readiness Flags: ${flags}
Notes: ${h.notes || 'None'}

Write the summary now:`;

    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 300,
        messages: [{ role: 'user', content: prompt }]
      })
    });

    const result = await response.json();

    if (result.error) {
      return res.status(500).json({ error: result.error.message });
    }

    const summary = result.content[0].text.trim();
    return res.status(200).json({ summary });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
}
