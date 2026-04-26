"""
Stack Overflow Search & RAG System for AI Coding Assistance

A comprehensive system that:
1. Searches Stack Overflow for coding questions
2. Indexes and stores answers locally
3. Performs semantic search on the indexed content
4. Generates contextual answers using RAG
"""

import os
import json
import sqlite3
import hashlib
import logging
from datetime import datetime, timedelta
from typing import List, Dict, Any, Optional, Tuple
from dataclasses import dataclass, asdict
from urllib.parse import quote_plus

import requests
import numpy as np
from bs4 import BeautifulSoup
from sentence_transformers import SentenceTransformer
import faiss
from openai import OpenAI
import tiktoken
from ratelimit import limits, sleep_and_retry

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("stackoverflow-rag")

@dataclass
class StackOverflowPost:
    """Represents a Stack Overflow question or answer"""
    id: str
    title: str
    body: str
    score: int
    answer_count: int = 0
    accepted_answer_id: Optional[str] = None
    tags: List[str] = None
    url: str = ""
    created_date: Optional[datetime] = None
    post_type: str = "question"  # "question" or "answer"
    parent_id: Optional[str] = None  # For answers, the question ID
    
    def to_text(self) -> str:
        """Convert post to text for embedding"""
        if self.post_type == "question":
            return f"Title: {self.title}\nTags: {', '.join(self.tags) if self.tags else ''}\n\n{self.body}"
        else:
            return f"Answer to: {self.title}\n\n{self.body}"
    
    def to_dict(self) -> dict:
        return asdict(self)

class StackOverflowAPI:
    """Handles interaction with Stack Overflow API and web scraping"""
    
    def __init__(self, api_key: Optional[str] = None):
        self.api_key = api_key
        self.base_url = "https://api.stackexchange.com/2.3"
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": "Mozilla/5.0 (compatible; AIRagBot/1.0)"
        })
    
    @sleep_and_retry
    @limits(calls=30, period=60)  # Rate limiting for free API
    def search_questions(
        self, 
        query: str, 
        tags: List[str] = None,
        page: int = 1,
        page_size: int = 20
    ) -> List[StackOverflowPost]:
        """Search for questions using Stack Exchange API"""
        params = {
            "order": "desc",
            "sort": "relevance",
            "q": query,
            "page": page,
            "pagesize": page_size,
            "site": "stackoverflow"
        }
        
        if tags:
            params["tagged"] = ";".join(tags)
        
        if self.api_key:
            params["key"] = self.api_key
        
        try:
            response = self.session.get(
                f"{self.base_url}/search/advanced",
                params=params,
                timeout=10
            )
            response.raise_for_status()
            data = response.json()
            
            questions = []
            for item in data.get("items", []):
                question = StackOverflowPost(
                    id=str(item["question_id"]),
                    title=item["title"],
                    body=self._clean_html(item.get("body", "")),
                    score=item["score"],
                    answer_count=item["answer_count"],
                    accepted_answer_id=str(item["accepted_answer_id"]) if item.get("accepted_answer_id") else None,
                    tags=item.get("tags", []),
                    url=item.get("link", ""),
                    created_date=datetime.fromtimestamp(item["creation_date"]),
                    post_type="question"
                )
                questions.append(question)
            
            return questions
            
        except Exception as e:
            logger.error(f"API search failed: {e}")
            return self._scrape_search_results(query, tags)
    
    def _scrape_search_results(
        self, 
        query: str, 
        tags: List[str] = None
    ) -> List[StackOverflowPost]:
        """Fallback: Scrape search results directly"""
        search_url = f"https://stackoverflow.com/search?q={quote_plus(query)}"
        if tags:
            search_url += f"+{'+'.join(tags)}"
        
        try:
            response = self.session.get(search_url, timeout=10)
            soup = BeautifulSoup(response.text, 'html.parser')
            
            questions = []
            for result in soup.select('.question-summary'):
                try:
                    question_id = result.get('data-questionid', '')
                    title_elem = result.select_one('.question-hyperlink')
                    excerpt_elem = result.select_one('.excerpt')
                    tags_elem = result.select_all('.post-tag')
                    
                    if title_elem and question_id:
                        question = StackOverflowPost(
                            id=question_id,
                            title=title_elem.text.strip(),
                            body=excerpt_elem.text.strip() if excerpt_elem else "",
                            score=0,  # Can't get score from scraping easily
                            answer_count=0,
                            tags=[tag.text for tag in tags_elem] if tags_elem else [],
                            url=f"https://stackoverflow.com/questions/{question_id}",
                            post_type="question"
                        )
                        questions.append(question)
                except Exception as e:
                    logger.warning(f"Failed to parse search result: {e}")
                    continue
            
            return questions
            
        except Exception as e:
            logger.error(f"Scraping failed: {e}")
            return []
    
    def get_question_details(
        self, 
        question_id: str
    ) -> Tuple[Optional[StackOverflowPost], List[StackOverflowPost]]:
        """Get detailed question and its answers"""
        try:
            # Try API first
            params = {
                "order": "desc",
                "sort": "votes",
                "site": "stackoverflow",
                "filter": "withbody"  # Include body in response
            }
            
            response = self.session.get(
                f"{self.base_url}/questions/{question_id}",
                params=params,
                timeout=10
            )
            response.raise_for_status()
            data = response.json()
            
            if not data.get("items"):
                return None, []
            
            item = data["items"][0]
            question = StackOverflowPost(
                id=str(item["question_id"]),
                title=item["title"],
                body=self._clean_html(item.get("body", "")),
                score=item["score"],
                answer_count=item["answer_count"],
                accepted_answer_id=str(item["accepted_answer_id"]) if item.get("accepted_answer_id") else None,
                tags=item.get("tags", []),
                url=item.get("link", ""),
                created_date=datetime.fromtimestamp(item["creation_date"]),
                post_type="question"
            )
            
            # Get answers
            answers = []
            if "answers" in item:
                for ans in item["answers"]:
                    answer = StackOverflowPost(
                        id=str(ans["answer_id"]),
                        title=f"Answer to: {question.title}",
                        body=self._clean_html(ans.get("body", "")),
                        score=ans["score"],
                        post_type="answer",
                        parent_id=question_id,
                        created_date=datetime.fromtimestamp(ans["creation_date"])
                    )
                    answers.append(answer)
            
            return question, answers
            
        except Exception as e:
            logger.error(f"Failed to get question details via API: {e}")
            return self._scrape_question_details(question_id)
    
    def _scrape_question_details(
        self, 
        question_id: str
    ) -> Tuple[Optional[StackOverflowPost], List[StackOverflowPost]]:
        """Fallback: Scrape question details"""
        url = f"https://stackoverflow.com/questions/{question_id}"
        
        try:
            response = self.session.get(url, timeout=10)
            soup = BeautifulSoup(response.text, 'html.parser')
            
            # Parse question
            question_elem = soup.select_one('.question')
            if not question_elem:
                return None, []
            
            title = soup.select_one('.question-hyperlink').text.strip()
            body_elem = question_elem.select_one('.post-text')
            tags_elem = soup.select_all('.post-tag')
            
            question = StackOverflowPost(
                id=question_id,
                title=title,
                body=self._clean_html(str(body_elem)) if body_elem else "",
                score=int(question_elem.select_one('.vote-count-post').text) if question_elem.select_one('.vote-count-post') else 0,
                answer_count=0,
                tags=[tag.text for tag in tags_elem] if tags_elem else [],
                url=url,
                post_type="question"
            )
            
            # Parse answers
            answers = []
            for answer_elem in soup.select('.answer'):
                answer_id = answer_elem.get('data-answerid', '')
                body_elem = answer_elem.select_one('.post-text')
                score_elem = answer_elem.select_one('.vote-count-post')
                
                answer = StackOverflowPost(
                    id=answer_id,
                    title=f"Answer to: {title}",
                    body=self._clean_html(str(body_elem)) if body_elem else "",
                    score=int(score_elem.text) if score_elem else 0,
                    post_type="answer",
                    parent_id=question_id,
                    url=f"{url}#{answer_id}"
                )
                answers.append(answer)
            
            question.answer_count = len(answers)
            return question, answers
            
        except Exception as e:
            logger.error(f"Scraping question details failed: {e}")
            return None, []
    
    def _clean_html(self, html: str) -> str:
        """Remove HTML tags and clean text"""
        if not html:
            return ""
        soup = BeautifulSoup(html, 'html.parser')
        return soup.get_text(separator=' ', strip=True)

class EmbeddingManager:
    """Manages text embeddings and vector search"""
    
    def __init__(self, model_name: str = "all-MiniLM-L6-v2"):
        self.model = SentenceTransformer(model_name)
        self.embedding_dim = self.model.get_sentence_embedding_dimension()
        self.index = None
        self.id_to_index = {}
        self.documents = []
    
    def encode(self, texts: List[str]) -> np.ndarray:
        """Encode texts to embeddings"""
        return self.model.encode(texts, normalize_embeddings=True)
    
    def build_index(self, documents: List[Dict[str, Any]]):
        """Build FAISS index from documents"""
        self.documents = documents
        
        # Extract texts for embedding
        texts = []
        for doc in documents:
            if doc['post_type'] == 'question':
                text = f"QUESTION: {doc['title']}\nTAGS: {', '.join(doc['tags'])}\n{doc['body']}"
            else:
                text = f"ANSWER to: {doc['title']}\n{doc['body']}"
            texts.append(text)
        
        # Create embeddings
        embeddings = self.encode(texts)
        
        # Build FAISS index
        self.index = faiss.IndexFlatIP(self.embedding_dim)  # Inner product for cosine similarity
        self.index.add(embeddings.astype('float32'))
        
        # Map IDs to indices
        self.id_to_index = {doc['id']: i for i, doc in enumerate(documents)}
        
        logger.info(f"Built index with {len(documents)} documents")
    
    def search(
        self, 
        query: str, 
        k: int = 5
    ) -> List[Tuple[Dict[str, Any], float]]:
        """Search for similar documents"""
        if self.index is None:
            return []
        
        # Encode query
        query_embedding = self.encode([query])
        
        # Search
        scores, indices = self.index.search(query_embedding.astype('float32'), k)
        
        # Return results
        results = []
        for i, idx in enumerate(indices[0]):
            if idx >= 0 and idx < len(self.documents):
                doc = self.documents[idx]
                score = float(scores[0][i])
                results.append((doc, score))
        
        return results

class LocalStorage:
    """Manages local SQLite storage for cached Stack Overflow content"""
    
    def __init__(self, db_path: str = "stackoverflow_cache.db"):
        self.db_path = db_path
        self._init_db()
    
    def _init_db(self):
        """Initialize database tables"""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS questions (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    body TEXT,
                    score INTEGER,
                    answer_count INTEGER,
                    accepted_answer_id TEXT,
                    tags TEXT,
                    url TEXT,
                    created_date TIMESTAMP,
                    last_accessed TIMESTAMP,
                    access_count INTEGER DEFAULT 1
                )
            """)
            
            conn.execute("""
                CREATE TABLE IF NOT EXISTS answers (
                    id TEXT PRIMARY KEY,
                    question_id TEXT,
                    body TEXT,
                    score INTEGER,
                    url TEXT,
                    created_date TIMESTAMP,
                    last_accessed TIMESTAMP,
                    access_count INTEGER DEFAULT 1,
                    FOREIGN KEY (question_id) REFERENCES questions(id)
                )
            """)
            
            conn.execute("""
                CREATE TABLE IF NOT EXISTS search_cache (
                    query TEXT PRIMARY KEY,
                    results TEXT,
                    timestamp TIMESTAMP
                )
            """)
            
            # Create indexes
            conn.execute("CREATE INDEX IF NOT EXISTS idx_answers_question ON answers(question_id)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_questions_last_accessed ON questions(last_accessed)")
    
    def save_question(self, question: StackOverflowPost):
        """Save question to database"""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                INSERT OR REPLACE INTO questions 
                (id, title, body, score, answer_count, accepted_answer_id, tags, url, created_date, last_accessed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                question.id,
                question.title,
                question.body,
                question.score,
                question.answer_count,
                question.accepted_answer_id,
                json.dumps(question.tags or []),
                question.url,
                question.created_date,
                datetime.now()
            ))
    
    def save_answers(self, answers: List[StackOverflowPost]):
        """Save answers to database"""
        with sqlite3.connect(self.db_path) as conn:
            for answer in answers:
                conn.execute("""
                    INSERT OR REPLACE INTO answers 
                    (id, question_id, body, score, url, created_date, last_accessed)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, (
                    answer.id,
                    answer.parent_id,
                    answer.body,
                    answer.score,
                    answer.url,
                    answer.created_date,
                    datetime.now()
                ))
    
    def get_question(self, question_id: str) -> Optional[StackOverflowPost]:
        """Get question from database"""
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute("""
                SELECT * FROM questions WHERE id = ?
            """, (question_id,))
            
            row = cursor.fetchone()
            if row:
                # Update access count
                conn.execute("""
                    UPDATE questions 
                    SET access_count = access_count + 1, last_accessed = ?
                    WHERE id = ?
                """, (datetime.now(), question_id))
                
                return StackOverflowPost(
                    id=row['id'],
                    title=row['title'],
                    body=row['body'],
                    score=row['score'],
                    answer_count=row['answer_count'],
                    accepted_answer_id=row['accepted_answer_id'],
                    tags=json.loads(row['tags']) if row['tags'] else [],
                    url=row['url'],
                    created_date=datetime.fromisoformat(row['created_date']) if row['created_date'] else None,
                    post_type="question"
                )
        return None
    
    def get_answers(self, question_id: str) -> List[StackOverflowPost]:
        """Get answers for a question"""
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute("""
                SELECT * FROM answers WHERE question_id = ?
                ORDER BY score DESC
            """, (question_id,))
            
            answers = []
            for row in cursor.fetchall():
                answers.append(StackOverflowPost(
                    id=row['id'],
                    title=f"Answer to question {question_id}",
                    body=row['body'],
                    score=row['score'],
                    post_type="answer",
                    parent_id=question_id,
                    url=row['url'],
                    created_date=datetime.fromisoformat(row['created_date']) if row['created_date'] else None
                ))
            return answers
    
    def cache_search_results(self, query: str, results: List[Dict]):
        """Cache search results"""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                INSERT OR REPLACE INTO search_cache (query, results, timestamp)
                VALUES (?, ?, ?)
            """, (
                query.lower(),
                json.dumps(results),
                datetime.now()
            ))
    
    def get_cached_search(self, query: str, max_age_hours: int = 24) -> Optional[List[Dict]]:
        """Get cached search results if not too old"""
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute("""
                SELECT results, timestamp FROM search_cache 
                WHERE query = ? AND timestamp > ?
            """, (
                query.lower(),
                datetime.now() - timedelta(hours=max_age_hours)
            ))
            
            row = cursor.fetchone()
            if row:
                return json.loads(row[0])
        return None
    
    def get_popular_questions(self, limit: int = 10) -> List[StackOverflowPost]:
        """Get most frequently accessed questions"""
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute("""
                SELECT * FROM questions 
                ORDER BY access_count DESC, last_accessed DESC
                LIMIT ?
            """, (limit,))
            
            questions = []
            for row in cursor.fetchall():
                questions.append(StackOverflowPost(
                    id=row['id'],
                    title=row['title'],
                    body=row['body'],
                    score=row['score'],
                    answer_count=row['answer_count'],
                    accepted_answer_id=row['accepted_answer_id'],
                    tags=json.loads(row['tags']) if row['tags'] else [],
                    url=row['url'],
                    created_date=datetime.fromisoformat(row['created_date']) if row['created_date'] else None,
                    post_type="question"
                ))
            return questions

class RAGAnswerGenerator:
    """Generates answers using RAG with Stack Overflow content"""
    
    def __init__(
        self,
        embedding_manager: EmbeddingManager,
        openai_api_key: Optional[str] = None,
        model: str = "gpt-4"
    ):
        self.embedding_manager = embedding_manager
        self.openai_client = OpenAI(api_key=openai_api_key) if openai_api_key else None
        self.model = model
        self.tokenizer = tiktoken.encoding_for_model("gpt-4")
    
    def count_tokens(self, text: str) -> int:
        """Count tokens in text"""
        return len(self.tokenizer.encode(text))
    
    def prepare_context(self, documents: List[Tuple[Dict[str, Any], float]], max_tokens: int = 4000) -> str:
        """Prepare context from retrieved documents"""
        context_parts = []
        total_tokens = 0
        
        for doc, score in documents:
            if doc['post_type'] == 'question':
                text = f"[Question - Score: {doc['score']}, Relevance: {score:.2f}]\nTitle: {doc['title']}\nTags: {', '.join(doc['tags'])}\nContent: {doc['body']}"
            else:
                text = f"[Answer - Score: {doc['score']}, Relevance: {score:.2f}]\n{doc['body']}"
            
            tokens = self.count_tokens(text)
            
            if total_tokens + tokens <= max_tokens:
                context_parts.append(text)
                total_tokens += tokens
            else:
                break
        
        return "\n\n---\n\n".join(context_parts)
    
    def generate_answer(
        self,
        query: str,
        context: str,
        programming_language: Optional[str] = None
    ) -> str:
        """Generate answer using LLM"""
        if not self.openai_client:
            return "OpenAI API key required for answer generation. Please provide an API key."
        
        language_specific = f" in {programming_language}" if programming_language else ""
        
        system_prompt = """You are an expert programming assistant with access to Stack Overflow content. 
Your task is to provide accurate, helpful answers to programming questions based on the provided context.
When answering:
1. Synthesize information from multiple sources
2. Cite specific code examples when available
3. Explain concepts clearly
4. Note if there are multiple approaches or solutions
5. Be honest about limitations or if context is insufficient

Format your answer with clear sections:
- Summary (brief overview)
- Detailed Solution (with code if applicable)
- Important Considerations (edge cases, performance, etc.)
- References (which Stack Overflow posts informed your answer)"""
        
        user_prompt = f"""Question: {query}{language_specific}

Relevant Stack Overflow Content:
{context}

Please provide a comprehensive answer to this question based on the Stack Overflow content above."""

        try:
            response = self.openai_client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt}
                ],
                temperature=0.3,
                max_tokens=2000
            )
            
            return response.choices[0].message.content
            
        except Exception as e:
            logger.error(f"Failed to generate answer: {e}")
            return f"Error generating answer: {str(e)}"
    
    def generate_concise_answer(self, query: str, context: str) -> str:
        """Generate a concise answer for quick responses"""
        system_prompt = "Provide a concise, accurate answer to the programming question based on the Stack Overflow context. Be direct and include code if relevant."
        
        try:
            response = self.openai_client.chat.completions.create(
                model="gpt-3.5-turbo",
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": f"Question: {query}\n\nContext: {context}"}
                ],
                temperature=0.3,
                max_tokens=500
            )
            
            return response.choices[0].message.content
            
        except Exception as e:
            return f"Error: {str(e)}"

class StackOverflowRAG:
    """Main orchestrator for Stack Overflow RAG system"""
    
    def __init__(
        self,
        stackoverflow_api_key: Optional[str] = None,
        openai_api_key: Optional[str] = None,
        db_path: str = "stackoverflow_cache.db"
    ):
        self.api = StackOverflowAPI(api_key=stackoverflow_api_key)
        self.storage = LocalStorage(db_path)
        self.embedding_manager = EmbeddingManager()
        self.rag_generator = None
        
        if openai_api_key:
            self.rag_generator = RAGAnswerGenerator(
                embedding_manager=self.embedding_manager,
                openai_api_key=openai_api_key
            )
        
        self.documents = []
        self._load_cached_documents()
    
    def _load_cached_documents(self):
        """Load cached documents for embedding"""
        # Load popular questions from cache
        questions = self.storage.get_popular_questions(100)
        
        for question in questions:
            self.documents.append(question.to_dict())
            answers = self.storage.get_answers(question.id)
            for answer in answers:
                self.documents.append(answer.to_dict())
        
        if self.documents:
            self.embedding_manager.build_index(self.documents)
            logger.info(f"Loaded {len(self.documents)} documents from cache")
    
    def search_and_index(
        self,
        query: str,
        tags: List[str] = None,
        max_questions: int = 10,
        fetch_answers: bool = True
    ) -> List[Dict[str, Any]]:
        """Search Stack Overflow, index results, return documents"""
        
        # Check cache first
        cached_results = self.storage.get_cached_search(query)
        if cached_results:
            logger.info(f"Using cached results for: {query}")
            return cached_results
        
        # Search for questions
        questions = self.api.search_questions(query, tags, page_size=max_questions)
        
        results = []
        for question in questions:
            # Check if we already have this question
            cached_question = self.storage.get_question(question.id)
            if cached_question:
                question_dict = cached_question.to_dict()
                results.append(question_dict)
                
                if fetch_answers:
                    answers = self.storage.get_answers(question.id)
                    for answer in answers:
                        answer_dict = answer.to_dict()
                        results.append(answer_dict)
                continue
            
            # Fetch fresh data
            full_question, answers = self.api.get_question_details(question.id)
            if full_question:
                self.storage.save_question(full_question)
                question_dict = full_question.to_dict()
                results.append(question_dict)
                
                if answers:
                    self.storage.save_answers(answers)
                    for answer in answers:
                        results.append(answer.to_dict())
        
        # Cache results
        self.storage.cache_search_results(query, results)
        
        # Update embedding index
        new_documents = [doc for doc in results if doc not in self.documents]
        if new_documents:
            self.documents.extend(new_documents)
            self.embedding_manager.build_index(self.documents)
        
        return results
    
    def semantic_search(
        self,
        query: str,
        k: int = 5
    ) -> List[Tuple[Dict[str, Any], float]]:
        """Perform semantic search on indexed documents"""
        return self.embedding_manager.search(query, k)
    
    def answer_question(
        self,
        query: str,
        tags: List[str] = None,
        use_rag: bool = True,
        concise: bool = False
    ) -> str:
        """Main method to answer a programming question"""
        
        # Search and index relevant content
        logger.info(f"Searching for: {query}")
        documents = self.search_and_index(query, tags)
        
        if not documents:
            return "No relevant Stack Overflow content found for your query."
        
        # Perform semantic search on the results
        logger.info("Performing semantic search on indexed content")
        relevant_docs = self.semantic_search(query, k=10)
        
        if not relevant_docs:
            return "No semantically relevant content found."
        
        # If RAG generation is available, use it
        if use_rag and self.rag_generator:
            logger.info("Generating RAG answer")
            context = self.rag_generator.prepare_context(relevant_docs)
            
            if concise:
                return self.rag_generator.generate_concise_answer(query, context)
            else:
                return self.rag_generator.generate_answer(query, context)
        
        # Otherwise, return top results
        else:
            response = ["Top relevant Stack Overflow content:\n"]
            for doc, score in relevant_docs[:3]:
                if doc['post_type'] == 'question':
                    response.append(f"📌 Question: {doc['title']}")
                    response.append(f"🏷️ Tags: {', '.join(doc['tags'])}")
                    response.append(f"📊 Score: {doc['score']}")
                    response.append(f"💬 Answers: {doc['answer_count']}")
                else:
                    response.append(f"✅ Answer (Score: {doc['score']})")
                    response.append(doc['body'][:300] + "...")
                response.append(f"🎯 Relevance: {score:.2f}")
                response.append("-" * 50)
            
            return "\n".join(response)
    
    def get_trending_topics(self, days: int = 7) -> List[Dict]:
        """Get trending programming topics from Stack Overflow"""
        # This would require additional API calls or analysis
        # For now, return popular cached questions
        questions = self.storage.get_popular_questions(20)
        
        topics = []
        for q in questions:
            topics.append({
                "title": q.title,
                "tags": q.tags,
                "score": q.score,
                "url": q.url
            })
        
        return topics

# MCP Server Integration
from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "StackOverflow RAG",
    instructions="Stack Overflow search and RAG system for programming answers"
)

# Initialize RAG system
rag_system = StackOverflowRAG(
    stackoverflow_api_key=os.environ.get("STACKOVERFLOW_API_KEY"),
    openai_api_key=os.environ.get("OPENAI_API_KEY")
)

@mcp.tool()
async def search_stackoverflow(
    query: str,
    tags: str = "",
    max_results: int = 5
) -> str:
    """Search Stack Overflow for programming questions
    
    Args:
        query: The programming question or keywords to search for
        tags: Comma-separated tags to filter by (e.g., "python,async")
        max_results: Maximum number of questions to return (1-20)
    """
    tag_list = [t.strip() for t in tags.split(",")] if tags else []
    
    try:
        results = rag_system.search_and_index(
            query=query,
            tags=tag_list,
            max_questions=min(max_results, 20)
        )
        
        if not results:
            return "No results found."
        
        output = [f"🔍 Search results for: {query}\n"]
        
        questions_shown = 0
        for doc in results:
            if doc['post_type'] == 'question' and questions_shown < max_results:
                questions_shown += 1
                output.append(f"📌 {doc['title']}")
                output.append(f"   Score: {doc['score']} | Answers: {doc['answer_count']}")
                if doc['tags']:
                    output.append(f"   Tags: {', '.join(doc['tags'])}")
                output.append(f"   {doc.get('url', 'No URL')}")
                output.append("")
        
        return "\n".join(output)
        
    except Exception as e:
        return f"Error searching: {str(e)}"

@mcp.tool()
async def get_question_details(
    question_id: str,
    include_answers: bool = True
) -> str:
    """Get detailed information about a specific Stack Overflow question
    
    Args:
        question_id: The Stack Overflow question ID (numbers from URL)
        include_answers: Whether to include answers
    """
    try:
        question, answers = rag_system.api.get_question_details(question_id)
        
        if not question:
            return f"Question {question_id} not found."
        
        # Cache the results
        rag_system.storage.save_question(question)
        if answers:
            rag_system.storage.save_answers(answers)
        
        output = [
            f"📌 {question.title}",
            f"Score: {question.score} | Answers: {question.answer_count}",
            f"Tags: {', '.join(question.tags)}",
            f"URL: {question.url}",
            "\n📝 Question:",
            question.body[:500] + "..." if len(question.body) > 500 else question.body
        ]
        
        if include_answers and answers:
            output.append("\n💬 Top Answers:")
            for i, answer in enumerate(sorted(answers, key=lambda x: x.score, reverse=True)[:3], 1):
                output.append(f"\n{i}. Score: {answer.score}")
                output.append(answer.body[:300] + "..." if len(answer.body) > 300 else answer.body)
        
        return "\n".join(output)
        
    except Exception as e:
        return f"Error fetching question: {str(e)}"

@mcp.tool()
async def ask_programming_question(
    query: str,
    tags: str = "",
    use_rag: bool = True
) -> str:
    """Ask a programming question and get an AI-generated answer based on Stack Overflow
    
    Args:
        query: Your programming question
        tags: Comma-separated tags to focus the search (e.g., "python,flask")
        use_rag: Whether to use RAG for comprehensive answer (vs showing raw results)
    """
    tag_list = [t.strip() for t in tags.split(",")] if tags else []
    
    try:
        answer = rag_system.answer_question(
            query=query,
            tags=tag_list,
            use_rag=use_rag
        )
        return answer
        
    except Exception as e:
        return f"Error generating answer: {str(e)}"

@mcp.tool()
async def semantic_code_search(
    code_snippet: str,
    language: str = "",
    k: int = 5
) -> str:
    """Search for similar code patterns and solutions using semantic search
    
    Args:
        code_snippet: The code or problem description to search for
        language: Programming language (optional)
        k: Number of results to return
    """
    try:
        # Enhance query with language if provided
        query = code_snippet
        if language:
            query = f"[{language}] {query}"
        
        # First ensure we have some indexed content
        # For better results, we'd want to search Stack Overflow first
        # but that's async - for now, search existing index
        
        if not rag_system.documents:
            # Do a quick search to populate index
            rag_system.search_and_index(
                query=f"{language} {code_snippet[:50]}" if language else code_snippet[:50],
                max_questions=5
            )
        
        results = rag_system.semantic_search(query, k=min(k, 10))
        
        if not results:
            return "No semantically similar content found."
        
        output = [f"🔎 Semantic search results for:\n{code_snippet[:200]}...\n"]
        
        for doc, score in results:
            if doc['post_type'] == 'question':
                output.append(f"\n📌 Question (relevance: {score:.3f})")
                output.append(f"Title: {doc['title']}")
                if doc['tags']:
                    output.append(f"Tags: {', '.join(doc['tags'])}")
            else:
                output.append(f"\n✅ Answer (relevance: {score:.3f})")
                output.append(doc['body'][:300] + "...")
        
        return "\n".join(output)
        
    except Exception as e:
        return f"Error in semantic search: {str(e)}"

@mcp.tool()
async def get_trending_programming_topics() -> str:
    """Get currently trending programming topics from Stack Overflow"""
    try:
        topics = rag_system.get_trending_topics()
        
        if not topics:
            return "No trending topics available yet. Try searching for some questions first."
        
        output = ["📈 Trending Programming Topics\n"]
        
        for i, topic in enumerate(topics[:10], 1):
            output.append(f"{i}. {topic['title']}")
            if topic['tags']:
                output.append(f"   Tags: {', '.join(topic['tags'][:5])}")
            output.append(f"   Score: {topic['score']}")
            output.append("")
        
        return "\n".join(output)
        
    except Exception as e:
        return f"Error fetching trends: {str(e)}"

@mcp.tool()
async def solve_problem_with_examples(
    problem: str,
    language: str = "python",
    include_examples: bool = True
) -> str:
    """Solve a programming problem with code examples from Stack Overflow
    
    Args:
        problem: Description of the programming problem
        language: Programming language to focus on
        include_examples: Whether to include code examples
    """
    try:
        # Enhance query with language
        query = f"{language} {problem}"
        
        # Search and get RAG answer
        documents = rag_system.search_and_index(
            query=query,
            tags=[language],
            max_questions=10
        )
        
        if not documents:
            return f"No Stack Overflow content found for {problem} in {language}."
        
        # Semantic search for most relevant
        relevant = rag_system.semantic_search(problem, k=15)
        
        # Extract code examples
        code_examples = []
        solutions = []
        
        for doc, score in relevant:
            # Look for code blocks in the content
            import re
            code_blocks = re.findall(r'```(?:\w+)?\n(.*?)```', doc['body'], re.DOTALL)
            
            if code_blocks:
                for code in code_blocks[:2]:  # Limit per document
                    code_examples.append({
                        'code': code.strip(),
                        'language': language,
                        'relevance': score,
                        'source': 'answer' if doc['post_type'] == 'answer' else 'question'
                    })
            
            solutions.append({
                'content': doc['body'][:500],
                'type': doc['post_type'],
                'score': doc['score'],
                'relevance': score
            })
        
        # Build response
        response = [f"🔧 Solution for: {problem}\n"]
        
        if code_examples and include_examples:
            response.append("📝 Code Examples:")
            for i, example in enumerate(code_examples[:3], 1):
                response.append(f"\nExample {i} (relevance: {example['relevance']:.2f}):")
                response.append(f"```{language}")
                response.append(example['code'])
                response.append("```")
        
        response.append("\n💡 Explanation:")
        # Generate explanation using RAG if available
        if rag_system.rag_generator:
            context = rag_system.rag_generator.prepare_context(relevant[:5])
            explanation = rag_system.rag_generator.generate_concise_answer(problem, context)
            response.append(explanation)
        else:
            # Fallback to top solution
            if solutions:
                top = solutions[0]
                response.append(f"Top solution (score: {top['score']}):")
                response.append(top['content'][:300] + "...")
        
        return "\n".join(response)
        
    except Exception as e:
        return f"Error solving problem: {str(e)}"

if __name__ == "__main__":
    # Run as MCP server
    mcp.run(transport="streamable-http")

# This comprehensive Stack Overflow Search & RAG system provides:
# Key Features:
# 1. Multi-Source Search

#     Primary: Stack Exchange API (with rate limiting)

#     Fallback: Web scraping when API is unavailable

#     Local caching to reduce API calls

# 2. Semantic Search

#     Uses sentence-transformers for embedding generation

#     FAISS vector index for fast similarity search

#     Finds conceptually similar content, not just keyword matches

# 3. RAG Answer Generation

#     GPT-4 integration for intelligent answer synthesis

#     Context window management (token counting)

#     Concise and detailed answer modes

# 4. Local Storage

#     SQLite database for caching questions/answers

#     Tracks popular/frequently accessed content

#     Search result caching (24-hour TTL)

# 5. MCP Tools Provided:

#     search_stackoverflow - Basic keyword search

#     get_question_details - Fetch full question+answers

#     ask_programming_question - RAG-powered Q&A

#     semantic_code_search - Find similar code patterns

#     get_trending_topics - Popular programming topics

#     solve_problem_with_examples - Problem solving with code

# Usage Examples:
# python

# # Ask a programming question
# result = await ask_programming_question(
#     "How do I handle async/await in Python with asyncio?",
#     tags="python,asyncio",
#     use_rag=True
# )

# # Semantic code search
# similar = await semantic_code_search(
#     "async def fetch_data(): return await client.get()",
#     language="python"
# )

# # Solve specific problem
# solution = await solve_problem_with_examples(
#     "How to implement retry logic with exponential backoff?",
#     language="python"
# )

# Setup Requirements:
# bash

# pip install requests beautifulsoup4 sentence-transformers faiss-cpu openai tiktoken ratelimit numpy

# Environment Variables:

#     STACKOVERFLOW_API_KEY - Optional, for higher rate limits

#     OPENAI_API_KEY - Required for RAG generation

# The system is designed to be run as an MCP server, providing programming assistance through intelligent Stack Overflow integration and semantic search capabilities.