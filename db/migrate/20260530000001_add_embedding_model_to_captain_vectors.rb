# Tags every stored embedding with the model that produced it, so vectors from
# different providers (OpenAI text-embedding-3-small vs a Gemini embedding model)
# can coexist in the same vector(1536) column without ever being compared across
# models. Existing vectors are backfilled as OpenAI's historical default.
class AddEmbeddingModelToCaptainVectors < ActiveRecord::Migration[7.1]
  HISTORICAL_DEFAULT = 'text-embedding-3-small'.freeze

  def up
    add_column :captain_assistant_responses, :embedding_model, :string unless column_exists?(:captain_assistant_responses, :embedding_model)
    add_column :article_embeddings, :embedding_model, :string unless column_exists?(:article_embeddings, :embedding_model)

    add_index :captain_assistant_responses, :embedding_model, if_not_exists: true
    add_index :article_embeddings, :embedding_model, if_not_exists: true

    execute(
      "UPDATE captain_assistant_responses SET embedding_model = '#{HISTORICAL_DEFAULT}' " \
      'WHERE embedding IS NOT NULL AND embedding_model IS NULL'
    )
    execute(
      "UPDATE article_embeddings SET embedding_model = '#{HISTORICAL_DEFAULT}' " \
      'WHERE embedding IS NOT NULL AND embedding_model IS NULL'
    )
  end

  def down
    remove_index :captain_assistant_responses, :embedding_model, if_exists: true
    remove_index :article_embeddings, :embedding_model, if_exists: true
    remove_column :captain_assistant_responses, :embedding_model, if_exists: true
    remove_column :article_embeddings, :embedding_model, if_exists: true
  end
end
