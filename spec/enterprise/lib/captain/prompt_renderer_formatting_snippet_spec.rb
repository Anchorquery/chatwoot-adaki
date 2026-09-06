require 'rails_helper'

# Renders the real assistant/scenario templates (no File stubs, unlike
# prompt_renderer_spec.rb) so a Liquid slip in the formatting snippet fails
# here instead of at runtime.
RSpec.describe Captain::PromptRenderer do
  let(:base_context) do
    {
      name: 'Captain', description: '', product_name: 'Acme', scenarios: [], tools: [],
      title: 'Ventas', instructions: 'Vende', assistant_name: 'captain',
      response_guidelines: [], guardrails: []
    }
  end

  describe '.render with the formatting snippet' do
    %w[assistant scenario].each do |template|
      context "with the #{template} template" do
        it 'adds plain-text formatting rules on WhatsApp/SMS channels' do
          prompt = described_class.render(template, base_context.merge(channel_type: 'Channel::Api', plain_text_channel: true))

          expect(prompt).to include('# Message Formatting')
          expect(prompt).to include('messaging app (Channel::Api)')
          expect(prompt).to include('Never write Markdown links like [text](url)')
        end

        it 'says nothing about formatting on channels that render Markdown' do
          prompt = described_class.render(template, base_context.merge(channel_type: 'Channel::WebWidget', plain_text_channel: false))

          expect(prompt).not_to include('# Message Formatting')
        end
      end
    end

    it 'no longer asks the assistant to run the same search through two tools' do
      prompt = described_class.render('assistant', base_context)

      expect(prompt).to include('search the knowledge base ONCE with `faq_lookup`')
      expect(prompt).not_to include('verify it with `faq_lookup`')
    end

    # Pre-fetched FAQs ride on the user message (Captain::KnowledgePrefetcher),
    # never here: the system prompt has to stay identical across the turns of a
    # conversation for the provider's prefix cache to hit.
    %w[assistant scenario].each do |template|
      it "renders the #{template} prompt identically on two turns of the same conversation" do
        context = base_context.merge(channel_type: 'Channel::Api', plain_text_channel: true,
                                     conversation: { display_id: 7, status: 'pending' })

        first = described_class.render(template, context)
        second = described_class.render(template, context.merge(knowledge: "Question: q\nAnswer: a\n"))

        expect(second).to eq(first)
        expect(second).not_to include('Answer: a')
      end
    end

    it 'no longer forces a scenario to search the FAQs for greetings and small talk' do
      prompt = described_class.render('scenario', base_context)

      expect(prompt).to include('Do NOT search for greetings, thanks')
      expect(prompt).to include('reuse it instead of searching again')
      expect(prompt).not_to include('ALWAYS search the FAQs')
    end
  end
end
