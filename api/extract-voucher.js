export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return res.status(500).json({ error: 'API key not configured' });
  }

  try {
    const { pdf } = req.body;
    if (!pdf) {
      return res.status(400).json({ error: 'No PDF provided' });
    }

    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 1024,
        messages: [{
          role: 'user',
          content: [
            {
              type: 'document',
              source: {
                type: 'base64',
                media_type: 'application/pdf',
                data: pdf
              }
            },
            {
              type: 'text',
              text: `Extract the following fields from this NYC housing voucher document. Return ONLY valid JSON, no other text. If a field cannot be determined, use null.

{
  "voucher_program": "one of: CityFHEPS, FHEPS, Section 8/HCV, HASA, SOTA, HPD, or Other",
  "voucher_status": "one of: Active, Expired, Pending Renewal",
  "authorized_bedrooms": "one of: Studio, 1BR, 2BR, 3BR, 4BR",
  "voucher_expiration": "YYYY-MM-DD format or null",
  "head_of_household": "full name",
  "household_members": number,
  "monthly_income": number in dollars (0 if not found),
  "ssi_ssdi_amount": number in dollars (0 if not found),
  "tenant_contribution": number in dollars (0 if not found),
  "max_rent": number in dollars (0 if not found),
  "employment_status": "one of: Employed, Unemployed, SSI/SSDI, Other",
  "notes": "any additional relevant information from the document"
}`
            }
          ]
        }]
      })
    });

    const result = await response.json();

    if (result.error) {
      return res.status(500).json({ error: result.error.message });
    }

    // Parse Claude's response - extract JSON from the text
    const text = result.content[0].text;
    let extracted;
    try {
      // Try to parse directly
      extracted = JSON.parse(text);
    } catch {
      // Try to find JSON in the response
      const jsonMatch = text.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        extracted = JSON.parse(jsonMatch[0]);
      } else {
        return res.status(500).json({ error: 'Could not parse extraction result' });
      }
    }

    return res.status(200).json(extracted);
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
}
