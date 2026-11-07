# Recuperação de produtos com busca lexical, semântica e híbrida

Repositório de apoio ao Trabalho de Conclusão de Curso de **Matheus Calixto**, dedicado à comparação de estratégias de recuperação de produtos para sistemas RAG (*Retrieval-Augmented Generation*).

O projeto utiliza **n8n**, **PostgreSQL**, **pgvector** e o conjunto de dados **WANDS**, da Wayfair. Os workflows realizam a importação dos dados, a geração de embeddings, a execução das buscas e o cálculo das métricas. Também são disponibilizadas demonstrações de atendimento com busca híbrida.

A avaliação quantitativa mede a recuperação de produtos. A qualidade das respostas geradas pelo chatbot não é avaliada pelas métricas deste experimento.

## Arquivos

Os nomes abaixo consideram os arquivos na raiz do repositório. Remova sufixos de download, como `(1)` e `(2)`, antes de publicá-los.

| Arquivo | Finalidade |
| --- | --- |
| `research-db.sql` | Estrutura do banco: schema, tabelas, funções, índices e restrições. |
| `insert-dataset.json` | Importação dos produtos, consultas e julgamentos de relevância. |
| `embed-products.json` | Geração e armazenamento dos embeddings dos produtos. |
| `embed-queries.json` | Geração e armazenamento dos embeddings das consultas. |
| `rank-metrics.json` | Execução do experimento e exportação das métricas. |
| `chatbot-hybrid-search.json` | Subworkflow de recuperação híbrida utilizado pelas demonstrações. |
| `simple-demo.json` | Demonstração de chatbot no n8n. |
| `evolutionapi-demo.json` | Demonstração integrada à Evolution API. |
| `resumo.csv` | Resultados agregados por método e corte K. |
| `por_consulta.csv` | Resultados individuais por consulta, método e corte K. |
| `LICENSE` | Licença MIT do código e da documentação original. |

## Métodos de busca

- **Lexical:** busca textual do PostgreSQL com configuração `english`, `websearch_to_tsquery`, ordenação por `ts_rank_cd` e índice GIN.
- **Semântica:** recuperação por distância de cosseno entre embeddings, utilizando o operador `<=>` do pgvector.
- **Híbrida:** combinação das posições dos rankings lexical e semântico por *Reciprocal Rank Fusion* (RRF), com pesos configuráveis.

A busca híbrida solicita até `2 × top_k` candidatos a cada componente antes da fusão. O SQL disponibilizado não cria índices vetoriais aproximados HNSW ou IVFFlat; isso deve ser considerado ao interpretar os tempos medidos.

## Base de dados

O [WANDS — Wayfair ANnotation Dataset](https://github.com/wayfair/WANDS) contém 42.994 produtos, 480 consultas e 233.448 julgamentos de relevância. Os rótulos são `Exact`, `Partial` e `Irrelevant`.

Baixe os arquivos diretamente do repositório original, na pasta `dataset`. Os dados brutos e os embeddings não estão incluídos no dump de estrutura deste projeto.

Os embeddings dos produtos utilizam nome e descrição. Os workflows de geração estão configurados com o identificador `models/gemini-embedding-2`, sem definir explicitamente `outputDimensionality`. Produtos e consultas precisam utilizar o mesmo modelo e dimensões compatíveis. Se o modelo for alterado, gere novamente ambos os conjuntos de embeddings e registre a alteração no experimento.

## Requisitos

- PostgreSQL com a extensão pgvector instalada no servidor.
- n8n com os tipos de nós utilizados nos arquivos JSON e acesso ao banco.
- Acesso à API de embeddings configurada nos workflows.
- Para as demonstrações: credenciais do modelo de linguagem e Redis; a demonstração de integração também requer Evolution API.

O dump foi gerado no PostgreSQL **15.4**. Registre as versões de n8n e pgvector da sua execução, além do modelo de embeddings e dos recursos da máquina. Os workflows exportados, isoladamente, não determinam a versão exata do n8n usada no experimento.

## Como executar

### 1. Preparar o banco

Crie um banco vazio e execute `research-db.sql`. Exemplo, com o banco `vector` já criado:

```bash
psql -h SEU_HOST -p 5432 -U SEU_USUARIO -d vector -v ON_ERROR_STOP=1 -f research-db.sql
```

O usuário precisa ter permissão para criar os objetos e habilitar a extensão. O script cria o schema `rag` e não deve ser reaplicado sobre uma instalação já preenchida. Ele não inclui produtos, consultas, embeddings ou resultados de execuções anteriores.

### 2. Importar os workflows e configurar o acesso

Importe os JSONs no n8n e selecione suas próprias credenciais nos nós PostgreSQL, HTTP e de modelos de linguagem. As referências a credenciais de outra instalação não fornecem acesso aos serviços.

Nos workflows de embeddings, configure a autenticação da API. O nó `set-keys` contém o marcador `GEMINI-CREDENTIAL`; não publique chaves reais ao exportar sua configuração. Prefira armazenar a autenticação em credenciais do n8n.

### 3. Importar o WANDS

Execute `insert-dataset.json` e envie os arquivos pelo formulário, nesta ordem:

| Arquivo do WANDS | Opção no formulário |
| --- | --- |
| `product.csv` | `products` |
| `query.csv` | `queries` |
| `label.csv` | `ground_truth` |

O importador está configurado para campos separados por tabulação. Importe os julgamentos após produtos e consultas, pois existem chaves estrangeiras. Evite repetir a importação de arquivos já carregados.

### 4. Gerar os embeddings

Execute `embed-products.json` e depois `embed-queries.json`.

**Cada seleção carrega até 100 registros.** Com a configuração fornecida de uma entrada em `set-keys`, cada execução processa até um lote. Repita as execuções até não haver pendências; o laço atual percorre as entradas de chaves, não todo o catálogo automaticamente.

Verifique as pendências no banco:

```sql
SELECT count(*) AS produtos_pendentes
FROM rag.products p
LEFT JOIN rag.documents d ON d.product_id = p.id
WHERE d.product_id IS NULL OR d.embedding IS NULL;

SELECT count(*) AS consultas_pendentes
FROM rag.test_queries
WHERE embedding IS NULL;
```

Ambas as contagens devem ser zero. O seletor de produtos busca produtos sem documento; um documento existente com embedding nulo exige correção específica antes da avaliação.

### 5. Executar a avaliação

Abra `rank-metrics.json` e confira o nó `Configurar1`:

| Parâmetro | Configuração fornecida |
| --- | --- |
| `query_limit` | `0`: todas as consultas; `10` permite um teste piloto. |
| `top_k` | `10`, com métricas também calculadas em K = 5. |
| `repetitions` | `5` repetições medidas por consulta e método. |
| `warmup_repetitions` | `1` repetição de aquecimento, excluída das métricas de latência. |
| `seed` | `42`, para a ordem pseudoaleatória de execução. |
| `full_text_weight` / `semantic_weight` | `1` / `1`. |
| `rrf_k` | `50`, constante de suavização do RRF, distinta do corte K. |

Atualize os campos descritivos `embedding_model` e `environment` para refletir a execução real. Eles são metadados e não alteram o modelo chamado nem os recursos disponíveis.

Execute o workflow até o final. Com 480 consultas e a configuração acima, são realizadas 8.640 buscas, incluindo o aquecimento. O nome do experimento é gerado automaticamente. Ao concluir, baixe `resumo.csv` e `por_consulta.csv` na saída do nó `Calcular metricas e CSV`.

## Critérios das métricas

### Métricas binárias: 379 consultas

Para Precision@K, Recall@K, MRR@K e Hit Rate@K, somente o rótulo `Exact` é considerado relevante.

Das 480 consultas, 101 não possuem nenhum produto julgado como `Exact`. O Recall é indefinido nesses casos; Precision, reciprocal rank e Hit Rate seriam zero sob a convenção usada, independentemente do método. Por isso, as quatro médias binárias são calculadas sobre o mesmo conjunto de **379 consultas com `exact_count > 0`**, também identificado como elegível para MRR.

A elegibilidade depende dos julgamentos do dataset, e não do sucesso da busca. Uma consulta elegível sem acertos continua na média com valor zero. As consultas excluídas permanecem no CSV por consulta, com `binary_eligible=false` e campos binários vazios.

- **Precision@K:** quantidade de produtos `Exact` recuperados dividida por K, mesmo quando são retornados menos de K produtos.
- **Recall@K:** quantidade de produtos `Exact` recuperados dividida pelo total de produtos `Exact` julgados para a consulta.
- **MRR@K:** média do inverso da posição do primeiro `Exact` entre as primeiras K posições; zero quando não há acerto.
- **Hit Rate@K:** proporção das consultas elegíveis com pelo menos um `Exact` entre as primeiras K posições.

### nDCG, cobertura e latência

O nDCG utiliza graus 2 para `Exact`, 1 para `Partial` e 0 para os demais casos, com ganho `2^grau − 1` e desconto logarítmico. Sua média considera consultas com IDCG positivo: **479 consultas nos resultados disponibilizados**.

Produtos sem julgamento recebem ganho zero no cálculo; as colunas de cobertura e de itens não julgados permitem acompanhar essa limitação. Ausência de julgamento não equivale a uma confirmação de irrelevância.

A latência considera as **480 consultas**, excluindo o aquecimento: são 2.400 medições por método. O cronômetro mede recuperação e materialização do ranking no PostgreSQL; não inclui geração de embeddings, rede, escrita dos resultados ou resposta do chatbot.

As métricas de qualidade utilizam o ranking da primeira repetição medida. Os cortes 5 e 10 são calculados a partir da mesma busca top-10; a latência repetida nas duas linhas do resumo corresponde a essa busca, e não a experimentos separados para cada corte.

## Resultados disponibilizados

Os CSVs usam codificação UTF-8 com BOM, separador `;` e vírgula decimal. `resumo.csv` contém seis linhas de resultados e `por_consulta.csv`, 2.880 linhas: 480 consultas × 3 métodos × 2 cortes.

Valores abaixo extraídos de `resumo.csv`, com arredondamento apenas para apresentação:

| Método | Precision@10 | Recall@10 | MRR@10 | Hit Rate@10 | nDCG@10 | Latência média (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Lexical | 0,3881 | 0,2217 | 0,6403 | 0,7388 | 0,4119 | 1,98 |
| Semântica | 0,4449 | 0,2053 | 0,6072 | 0,7889 | 0,6612 | 474,71 |
| Híbrida | 0,4718 | 0,2871 | 0,7241 | 0,8786 | 0,6892 | 1035,94 |

Os tempos dependem do ambiente, da carga e da configuração do banco. Os workflows apresentados calculam métricas descritivas e exportam CSVs; não executam testes de significância ou geração de figuras. Análises estatísticas adicionais devem ser acompanhadas dos respectivos scripts quando utilizadas no trabalho.

## Demonstrações de chatbot

Importe `chatbot-hybrid-search.json` antes de configurar `simple-demo.json` ou `evolutionapi-demo.json`. Nos nós de ferramenta de busca das demonstrações, selecione o subworkflow importado na sua instalação: IDs de workflows não são portáveis entre instâncias.

Configure o Redis, o modelo de linguagem e a autenticação dos serviços. Para a Evolution API, ajuste também URL, instância, webhook e segredo de validação. As demonstrações são opcionais e não precisam ser executadas para reproduzir as métricas de recuperação.

## Publicação e credenciais

Antes de publicar exportações, remova chaves, tokens, senhas e dados de teste privados. O `.gitignore` exclui arquivos locais de configuração, backups e dados brutos, mas não remove segredos escritos dentro de um JSON nem arquivos já rastreados pelo Git. Os workflows, o SQL de estrutura e os CSVs de resultados devem permanecer versionados.

## Licença e referência

O código e a documentação original deste projeto são disponibilizados sob a [licença MIT](LICENSE). É permitido usar, modificar e distribuir, inclusive comercialmente, mantendo o aviso de direitos autorais e o texto da licença. O software é fornecido sem garantia.

O WANDS e outros componentes de terceiros mantêm suas próprias licenças e atribuições. Consulte a [licença do WANDS](https://github.com/wayfair/WANDS/blob/main/LICENSE) ao reutilizar seus dados, inclusive textos de consultas presentes nos resultados.

Referência do dataset: Chen, Y.; Liu, S.; Liu, Z.; Sun, W.; Baltrunas, L.; Schroeder, B. **WANDS: Dataset for Product Search Relevance Assessment**. ECIR, 2022. [Repositório oficial](https://github.com/wayfair/WANDS).
