// varnick.com: the product page, served as one constant document.
import page from './page.html'

export default {
  fetch(): Response {
    return new Response(page, {
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'public, max-age=300',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'strict-origin-when-cross-origin',
      },
    })
  },
}
