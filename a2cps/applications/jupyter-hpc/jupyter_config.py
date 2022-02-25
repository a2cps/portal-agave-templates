# Configuration file for ipython-notebook.
import os
import ssl

c = get_config()

c.IPKernelApp.pylab = "inline"  # if you want plotting support always
c.NotebookApp.ip = "0.0.0.0"
c.NotebookApp.port = 5902
c.NotebookApp.open_browser = False
c.NotebookApp.mathjax_url = u"https://cdn.mathjax.org/mathjax/latest/MathJax.js"
c.NotebookApp.allow_origin = u"*"
c.NotebookApp.ssl_options = {"ssl_version": ssl.PROTOCOL_TLSv1_2}
# Set default umask
# 18 = octal 022
# 23 = octal 027 -rw-r-----
os.umask(23)
# Disable use of send2trash since it's not compatible with TACC filesystems
# See https://github.com/jupyter/notebook/issues/3130
c.FileContentsManager.delete_to_trash = False
