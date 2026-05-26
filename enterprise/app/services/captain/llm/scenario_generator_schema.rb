class Captain::Llm::ScenarioGeneratorSchema < RubyLLM::Schema
  string :title,
         description: 'Short, descriptive scenario title (max 80 chars). Plain text, no markdown.',
         max_length: 80

  string :description,
         description: 'One-sentence summary (max 200 chars) of when and why this scenario triggers.',
         max_length: 200

  string :instruction,
         description: 'Step-by-step handling instructions in Markdown. ' \
                      'Reference available tools using the exact format: [@Tool Name](tool://tool_id). ' \
                      'Use bullet lists and numbered steps. Be concrete and actionable. Max 4000 chars.',
         max_length: 4_000
end
