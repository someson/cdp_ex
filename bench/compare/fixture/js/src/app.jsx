// The `js` fixture: a small React app in the RealWorld ("Conduit") style. Nothing
// is in the HTML; the list and the article view are rendered in the browser from
// the fixture's JSON API. Build: see ../README.md (npm run build in this dir).
import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

function useRoute() {
  const [hash, setHash] = useState(window.location.hash);
  useEffect(() => {
    const on = () => setHash(window.location.hash);
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  const m = hash.match(/^#\/article\/(.+)$/);
  return m ? { article: m[1] } : { home: true };
}

function useJson(url) {
  const [data, setData] = useState(null);
  useEffect(() => {
    let live = true;
    setData(null);
    fetch(url).then((r) => r.json()).then((d) => live && setData(d));
    return () => { live = false; };
  }, [url]);
  return data;
}

function Tags({ tags }) {
  return (
    <ul className="tag-list">
      {tags.map((t) => <li key={t} className="tag-default tag-pill tag-outline">{t}</li>)}
    </ul>
  );
}

function Preview({ a }) {
  const [liked, setLiked] = useState(false);
  return (
    <div className="article-preview">
      <div className="article-meta">
        <img src={`/img/32x32/${a.author.id}.png`} alt="" />
        <div className="info">
          <span className="author">{a.author.username}</span>
          <span className="date">{new Date(a.createdAt).toDateString()}</span>
        </div>
        <button className={liked ? "btn btn-primary" : "btn btn-outline-primary"} onClick={() => setLiked(!liked)}>
          ♥ {a.favoritesCount + (liked ? 1 : 0)}
        </button>
      </div>
      <a href={`#/article/${a.slug}`} className="preview-link">
        <h2>{a.title}</h2>
        <p>{a.description}</p>
        <span>Read more...</span>
        <Tags tags={a.tagList} />
      </a>
    </div>
  );
}

function Home() {
  const feed = useJson("/api/articles?limit=20");
  const tags = useJson("/api/tags");
  return (
    <div className="home-page">
      <div className="banner"><div className="container"><h1 className="logo-font">conduit</h1><p>A place to share your knowledge.</p></div></div>
      <div className="container page">
        <div className="row">
          <div className="col-md-9">
            {feed ? feed.articles.map((a) => <Preview key={a.slug} a={a} />) : <div className="loading">Loading articles...</div>}
          </div>
          <div className="col-md-3">
            <div className="sidebar"><p>Popular Tags</p>{tags ? <Tags tags={tags.tags} /> : null}</div>
          </div>
        </div>
      </div>
    </div>
  );
}

function Article({ slug }) {
  const data = useJson(`/api/articles/${slug}`);
  const comments = useJson(`/api/articles/${slug}/comments`);
  if (!data) return <div className="loading">Loading article...</div>;
  const a = data.article;
  return (
    <div className="article-page">
      <div className="banner"><div className="container"><h1>{a.title}</h1></div></div>
      <div className="container page">
        <div className="article-content">{a.body.split("\n\n").map((p, i) => <p key={i}>{p}</p>)}</div>
        <Tags tags={a.tagList} />
        <div className="comments">
          {comments ? comments.comments.map((c) => <div key={c.id} className="card"><div className="card-block">{c.body}</div></div>) : null}
        </div>
      </div>
    </div>
  );
}

function App() {
  const route = useRoute();
  return (
    <>
      <nav className="navbar"><a className="navbar-brand" href="#/">conduit</a></nav>
      {route.home ? <Home /> : <Article slug={route.article} />}
      <footer><span>An interactive learning project. Code &amp; design licensed under MIT.</span></footer>
    </>
  );
}

createRoot(document.getElementById("root")).render(<App />);
