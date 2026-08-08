import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './styles/app.css'

const root = document.getElementById('root')
if (!root) throw new Error('#root not found')

createRoot(root).render(
  <StrictMode>
    <div className="p-8 font-mono text-sm">
      varnick — Core is up. No machines yet.
    </div>
  </StrictMode>,
)
