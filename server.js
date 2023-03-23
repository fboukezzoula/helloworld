const http = require('http')

const port = 80

const server = http.createServer((request, response) => {
  response.writeHead(200, {'Content-Type': 'text/html'})
  response.write(`
    <!DOCTYPE html>
    <html>
      <head>
        <title>Hello World</title>
      </head>
      <body>
        <h1>Hello World</h1>
        <p>Node version: ${process.env.NODE_VERSION}</p>
        <p>Build version: ${process.env.BUILD}</p>
        <script>
          setInterval(() => {
            console.log('Refreshing page...')
            location.reload()
          }, 5000)
        </script>
      </body>
    </html>
  `)
  response.end()
})

server.listen(port)
