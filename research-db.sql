--
-- PostgreSQL database dump
--

-- Dumped from database version 15.4 (Debian 15.4-2.pgdg120+1)
-- Dumped by pg_dump version 15.4 (Debian 15.4-2.pgdg120+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: rag; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA rag;


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: documents_fts_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.documents_fts_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
new.fts := to_tsvector('portuguese', coalesce(new.content, ''));
return new;
end
$$;


--
-- Name: hybrid_search(text, public.vector, integer, double precision, double precision, integer); Type: FUNCTION; Schema: rag; Owner: -
--

CREATE FUNCTION rag.hybrid_search(query_text text, query_embedding public.vector, match_count integer, full_text_weight double precision DEFAULT 1, semantic_weight double precision DEFAULT 1, rrf_k integer DEFAULT 50) RETURNS TABLE(product_id integer, name text, description text, score double precision)
    LANGUAGE sql STABLE
    AS $$
WITH full_text AS (
SELECT
k.product_id,
ROW_NUMBER() OVER (
ORDER BY k.score DESC, k.product_id ASC
) AS rank_ix
FROM rag.keyword_search(
query_text,
match_count * 2
) AS k
),
semantic AS (
SELECT
s.product_id,
ROW_NUMBER() OVER (
ORDER BY s.score DESC, s.product_id ASC
) AS rank_ix
FROM rag.semantic_search(
query_embedding,
match_count * 2
) AS s
),
fused AS (
SELECT
COALESCE(f.product_id, s.product_id) AS product_id,

COALESCE(
full_text_weight /
(rrf_k::double precision + f.rank_ix),
0.0
)
+
COALESCE(
semantic_weight /
(rrf_k::double precision + s.rank_ix),
0.0
) AS score

FROM full_text AS f
FULL OUTER JOIN semantic AS s
ON s.product_id = f.product_id
)
SELECT
p.id AS product_id,
p.name,
p.description,
f.score
FROM fused AS f
JOIN rag.products AS p
ON p.id = f.product_id
ORDER BY
f.score DESC,
p.id ASC
LIMIT match_count;
$$;


--
-- Name: keyword_search(text, integer); Type: FUNCTION; Schema: rag; Owner: -
--

CREATE FUNCTION rag.keyword_search(query_text text, match_count integer) RETURNS TABLE(product_id integer, name text, description text, score double precision)
    LANGUAGE sql STABLE
    AS $$
WITH search_query AS (
SELECT websearch_to_tsquery(
'english'::regconfig,
query_text
) AS tsquery
)
SELECT
p.id AS product_id,
p.name,
p.description,
ts_rank_cd(d.fts, q.tsquery)::double precision AS score
FROM rag.documents AS d
JOIN rag.products AS p
ON p.id = d.product_id
CROSS JOIN search_query AS q
WHERE d.fts @@ q.tsquery
ORDER BY
score DESC,
p.id ASC
LIMIT match_count;
$$;


--
-- Name: record_test_search(text, integer, text, jsonb); Type: FUNCTION; Schema: rag; Owner: -
--

CREATE FUNCTION rag.record_test_search(p_experiment text, p_query_id integer, p_method text, p_config jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  q rag.test_queries%ROWTYPE;
  started timestamptz;
  elapsed_ms double precision;
  results jsonb;
  search_id bigint;
  k integer := (p_config->>'top_k')::integer;
BEGIN
  IF k IS NULL OR k < 10 THEN RAISE EXCEPTION 'top_k deve ser pelo menos 10'; END IF;
  SELECT * INTO STRICT q FROM rag.test_queries WHERE query_id=p_query_id;
  IF q.embedding IS NULL THEN RAISE EXCEPTION 'Consulta % sem embedding',p_query_id; END IF;

  -- Região medida: recuperação e materialização do ranking em memória.
  started := clock_timestamp();
  IF p_method='lexical' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('rank',r.ordinality,
      'product_id',r.product_id,'score',r.score) ORDER BY r.ordinality),'[]'::jsonb)
    INTO results FROM rag.keyword_search(q.query,k) WITH ORDINALITY r;
  ELSIF p_method='semantic' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('rank',r.ordinality,
      'product_id',r.product_id,'score',r.score) ORDER BY r.ordinality),'[]'::jsonb)
    INTO results FROM rag.semantic_search(q.embedding,k) WITH ORDINALITY r;
  ELSIF p_method='hybrid' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('rank',r.ordinality,
      'product_id',r.product_id,'score',r.score) ORDER BY r.ordinality),'[]'::jsonb)
    INTO results FROM rag.hybrid_search(q.query,q.embedding,k,
      (p_config->>'full_text_weight')::float8,
      (p_config->>'semantic_weight')::float8,
      (p_config->>'rrf_k')::integer) WITH ORDINALITY r;
  ELSE
    RAISE EXCEPTION 'Método inválido: %',p_method;
  END IF;
  elapsed_ms := extract(epoch FROM clock_timestamp()-started)*1000;

  -- Escrita fica fora do cronômetro. Se houver erro, a chamada inteira falha.
  INSERT INTO rag.test_searches(experiment_name,query_id,method,top_k,
    configuration,status,latency_ms,created_at,completed_at)
  VALUES(p_experiment,p_query_id,p_method,k,p_config,
    coalesce(p_config->>'completed_status','completed'),elapsed_ms,clock_timestamp(),clock_timestamp())
  RETURNING id INTO search_id;
  INSERT INTO rag.test_results(search_id,rank,product_id,score)
  SELECT search_id,x.rank,x.product_id,x.score
  FROM jsonb_to_recordset(results) AS x(rank integer,product_id integer,score double precision);
  RETURN search_id;
END $$;


--
-- Name: semantic_search(public.vector, integer); Type: FUNCTION; Schema: rag; Owner: -
--

CREATE FUNCTION rag.semantic_search(query_embedding public.vector, match_count integer) RETURNS TABLE(product_id integer, name text, description text, score double precision)
    LANGUAGE sql STABLE
    AS $$
SELECT
p.id AS product_id,
p.name,
p.description,
1.0 - (d.embedding <=> query_embedding) AS score
FROM rag.documents AS d
JOIN rag.products AS p
ON p.id = d.product_id
WHERE d.embedding IS NOT NULL
ORDER BY
d.embedding <=> query_embedding ASC,
p.id ASC
LIMIT match_count;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: documents; Type: TABLE; Schema: rag; Owner: -
--

CREATE TABLE rag.documents (
    id bigint NOT NULL,
    product_id integer NOT NULL,
    content text NOT NULL,
    fts tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, content)) STORED,
    embedding public.vector,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: documents_id_seq; Type: SEQUENCE; Schema: rag; Owner: -
--

ALTER TABLE rag.documents ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rag.documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: products; Type: TABLE; Schema: rag; Owner: -
--

CREATE TABLE rag.products (
    id integer NOT NULL,
    name text NOT NULL,
    description text,
    class text,
);


--
-- Name: test_labels; Type: TABLE; Schema: rag; Owner: -
--

CREATE TABLE rag.test_labels (
    id integer NOT NULL,
    query_id integer NOT NULL,
    product_id integer NOT NULL,
    label text NOT NULL,
    CONSTRAINT test_labels_label_check CHECK ((label = ANY (ARRAY['Exact'::text, 'Partial'::text, 'Irrelevant'::text])))
);


--
-- Name: test_queries; Type: TABLE; Schema: rag; Owner: -
--

CREATE TABLE rag.test_queries (
    query_id integer NOT NULL,
    query text NOT NULL,
    query_class text,
    embedding public.vector
);


--
-- Name: test_results; Type: TABLE; Schema: rag; Owner: -
--

CREATE TABLE rag.test_results (
    search_id bigint NOT NULL,
    rank integer NOT NULL,
    product_id integer NOT NULL,
    score double precision,
    CONSTRAINT test_results_rank_check CHECK ((rank > 0))
);


--
-- Name: test_searches; Type: TABLE; Schema: rag; Owner: -
--

CREATE TABLE rag.test_searches (
    id bigint NOT NULL,
    experiment_name text NOT NULL,
    query_id integer NOT NULL,
    method text NOT NULL,
    top_k integer DEFAULT 10 NOT NULL,
    configuration jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'running'::text NOT NULL,
    latency_ms double precision,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT test_searches_latency_ms_check CHECK ((latency_ms >= (0)::double precision)),
    CONSTRAINT test_searches_method_check CHECK ((method = ANY (ARRAY['lexical'::text, 'semantic'::text, 'hybrid'::text]))),
    CONSTRAINT test_searches_status_check CHECK ((status = ANY (ARRAY['running'::text, 'completed'::text, 'failed'::text]))),
    CONSTRAINT test_searches_top_k_check CHECK ((top_k > 0))
);


--
-- Name: test_searches_id_seq; Type: SEQUENCE; Schema: rag; Owner: -
--

ALTER TABLE rag.test_searches ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rag.test_searches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: documents documents_product_id_key; Type: CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.documents
    ADD CONSTRAINT documents_product_id_key UNIQUE (product_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: test_labels test_labels_pkey; Type: CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_labels
    ADD CONSTRAINT test_labels_pkey PRIMARY KEY (id);


--
-- Name: test_queries test_queries_pkey; Type: CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_queries
    ADD CONSTRAINT test_queries_pkey PRIMARY KEY (query_id);


--
-- Name: test_results test_results_pkey; Type: CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_results
    ADD CONSTRAINT test_results_pkey PRIMARY KEY (search_id, rank);


--
-- Name: test_results test_results_search_id_product_id_key; Type: CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_results
    ADD CONSTRAINT test_results_search_id_product_id_key UNIQUE (search_id, product_id);


--
-- Name: test_searches test_searches_pkey; Type: CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_searches
    ADD CONSTRAINT test_searches_pkey PRIMARY KEY (id);


--
-- Name: rag_documents_fts_idx; Type: INDEX; Schema: rag; Owner: -
--

CREATE INDEX rag_documents_fts_idx ON rag.documents USING gin (fts);


--
-- Name: rag_test_labels_product_idx; Type: INDEX; Schema: rag; Owner: -
--

CREATE INDEX rag_test_labels_product_idx ON rag.test_labels USING btree (product_id);


--
-- Name: rag_test_labels_query_product_idx; Type: INDEX; Schema: rag; Owner: -
--

CREATE INDEX rag_test_labels_query_product_idx ON rag.test_labels USING btree (query_id, product_id);


--
-- Name: rag_test_results_product_idx; Type: INDEX; Schema: rag; Owner: -
--

CREATE INDEX rag_test_results_product_idx ON rag.test_results USING btree (product_id);


--
-- Name: rag_test_searches_experiment_query_method_idx; Type: INDEX; Schema: rag; Owner: -
--

CREATE INDEX rag_test_searches_experiment_query_method_idx ON rag.test_searches USING btree (experiment_name, query_id, method);


--
-- Name: test_labels_query_product_eval_idx; Type: INDEX; Schema: rag; Owner: -
--

CREATE INDEX test_labels_query_product_eval_idx ON rag.test_labels USING btree (query_id, product_id);


--
-- Name: test_results_search_eval_idx; Type: INDEX; Schema: rag; Owner: -
--

CREATE INDEX test_results_search_eval_idx ON rag.test_results USING btree (search_id);


--
-- Name: test_searches_experiment_eval_idx; Type: INDEX; Schema: rag; Owner: -
--

CREATE INDEX test_searches_experiment_eval_idx ON rag.test_searches USING btree (experiment_name);


--
-- Name: documents documents_product_id_fkey; Type: FK CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.documents
    ADD CONSTRAINT documents_product_id_fkey FOREIGN KEY (product_id) REFERENCES rag.products(id) ON DELETE CASCADE;


--
-- Name: test_labels test_labels_product_id_fkey; Type: FK CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_labels
    ADD CONSTRAINT test_labels_product_id_fkey FOREIGN KEY (product_id) REFERENCES rag.products(id);


--
-- Name: test_labels test_labels_query_id_fkey; Type: FK CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_labels
    ADD CONSTRAINT test_labels_query_id_fkey FOREIGN KEY (query_id) REFERENCES rag.test_queries(query_id);


--
-- Name: test_results test_results_product_id_fkey; Type: FK CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_results
    ADD CONSTRAINT test_results_product_id_fkey FOREIGN KEY (product_id) REFERENCES rag.products(id);


--
-- Name: test_results test_results_search_id_fkey; Type: FK CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_results
    ADD CONSTRAINT test_results_search_id_fkey FOREIGN KEY (search_id) REFERENCES rag.test_searches(id) ON DELETE CASCADE;


--
-- Name: test_searches test_searches_query_id_fkey; Type: FK CONSTRAINT; Schema: rag; Owner: -
--

ALTER TABLE ONLY rag.test_searches
    ADD CONSTRAINT test_searches_query_id_fkey FOREIGN KEY (query_id) REFERENCES rag.test_queries(query_id);


--
-- PostgreSQL database dump complete
--

